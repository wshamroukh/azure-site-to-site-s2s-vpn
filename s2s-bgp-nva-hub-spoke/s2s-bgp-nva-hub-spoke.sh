# s2s with hub1 and two spoke vnets and an opnsense firewall on the hub1 vnet where 0.0.0.0/0 are routed from hub1 spokes vnets to the opnsense firewall
# variables
location1='centralindia'
location2='centralindia'
rg='s2s-nva-bgp'
hub1_vnet_name='hub1'
hub1_vnet_address='10.1.0.0/16'
hub1_gw_subnet_address='10.1.0.0/24'
hub1_gw_asn='65515'
hub1_vm_subnet_name='vm'
hub1_vm_subnet_address='10.1.1.0/24'

hub1_fw_subnet_name='fw'
hub1_fw_subnet_address='10.1.2.0/24'
hub1_fw_vm_image=$(az vm image list -l $location1 -p thefreebsdfoundation --sku 14_1-release-zfs --all --query "[?offer=='freebsd-14_1'].urn" -o tsv | sort -u | tail -n 1) && echo $hub1_fw_vm_image
az vm image terms accept --urn $hub1_fw_vm_image -o none

spoke1_vnet_name='spoke1'
spoke1_vnet_address='10.11.0.0/16'
spoke1_vm_subnet_name='vm'
spoke1_vm_subnet_address='10.11.1.0/24'

spoke2_vnet_name='spoke2'
spoke2_vnet_address='10.12.0.0/16'
spoke2_vm_subnet_name='vm'
spoke2_vm_subnet_address='10.12.1.0/24'

onprem1_vnet_name='onprem1'
onprem1_vnet_address='172.21.0.0/16'
onprem1_vm_subnet_name='vm'
onprem1_vm_subnet_address='172.21.1.0/24'
onprem1_gw_subnet_name='gw'
onprem1_gw_subnet_address='172.21.0.0/24'
onprem1_gw_asn=65521
onprem1_gw_vti0=172.21.0.250
onprem1_gw_vti1=172.21.0.251

onprem2_vnet_name='onprem2'
onprem2_vnet_address='172.22.0.0/16'
onprem2_vm_subnet_name='vm'
onprem2_vm_subnet_address='172.22.1.0/24'
onprem2_gw_subnet_name='gw'
onprem2_gw_subnet_address='172.22.0.0/24'
onprem2_gw_asn=65522
onprem2_gw_vti0=172.22.0.250
onprem2_gw_vti1=172.22.0.251

default0=0.0.0.0/1
default1=128.0.0.0/1
psk='secret12345'
tag='scenario=s2s-nva-hub-spoke'
admin_username=$(whoami)
admin_password='Test#123#123'
myip=$(curl -s4 https://ifconfig.co/)
vm_image=$(az vm image list -l $location1 -p Canonical -s 22_04-lts --all --query "[?offer=='0001-com-ubuntu-server-jammy'].urn" -o tsv | sort -u | tail -n 1) && echo $vm_image
vm_size=Standard_B2ats_v2

opnsense_init_file=~/opnsense_init.sh
cat <<EOF > $opnsense_init_file
#!/usr/local/bin/bash
echo $admin_password | sudo -S pkg update
sudo pkg upgrade -y
sed 's/#PermitRootLogin no/PermitRootLogin yes/g' /etc/ssh/sshd_config > /tmp/sshd_config
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config_tmp
sudo mv /tmp/sshd_config /etc/ssh/sshd_config
sudo /etc/rc.d/sshd restart
echo -e "$admin_password\n$admin_password" | sudo passwd root
fetch https://raw.githubusercontent.com/opnsense/update/master/src/bootstrap/opnsense-bootstrap.sh.in
sed 's/reboot/#reboot/' opnsense-bootstrap.sh.in >opnsense-bootstrap.sh.in.tmp
mv opnsense-bootstrap.sh.in.tmp opnsense-bootstrap.sh.in
sed 's/set -e/#set -e/' opnsense-bootstrap.sh.in >opnsense-bootstrap.sh.in.tmp
mv opnsense-bootstrap.sh.in.tmp opnsense-bootstrap.sh.in
sudo chmod +x opnsense-bootstrap.sh.in
sudo sh ~/opnsense-bootstrap.sh.in -y -r 24.7
sudo cp ~/config.xml /usr/local/etc/config.xml
sudo pkg upgrade
sudo pkg install -y bash git
sudo ln -s /usr/local/bin/python3.11 /usr/local/bin/python
git clone https://github.com/Azure/WALinuxAgent.git
cd ~/WALinuxAgent/
git checkout v2.11.1.12
sudo python setup.py install
sudo ln -sf /usr/local/sbin/waagent /usr/sbin/waagent
sudo service waagent start
sudo service waagent status
sudo reboot
EOF

onprem_gw_cloudinit_file=~/onprem_gw_cloudinit.txt
cat <<EOF > $onprem_gw_cloudinit_file
#cloud-config
runcmd:
  - curl -s https://deb.frrouting.org/frr/keys.gpg | sudo tee /usr/share/keyrings/frrouting.gpg > /dev/null
  - echo deb [signed-by=/usr/share/keyrings/frrouting.gpg] https://deb.frrouting.org/frr \$(lsb_release -s -c) frr-stable | sudo tee -a /etc/apt/sources.list.d/frr.list
  - sudo apt update && sudo apt install -y frr frr-pythontools
  - sudo apt install -y strongswan tcptraceroute
  - sudo sed -i "/bgpd=no/ s//bgpd=yes/" /etc/frr/daemons
  - sudo cat /etc/frr/daemons
  - sudo service frr restart
  - touch /etc/strongswan.d/ipsec-vti.sh
  - chmod +x /etc/strongswan.d/ipsec-vti.sh
  - cp /etc/ipsec.conf /etc/ipsec.conf.bak
  - cp /etc/ipsec.secrets /etc/ipsec.secrets.bak
  - echo "net.ipv4.conf.all.forwarding=1" | sudo tee -a /etc/sysctl.conf
  - echo "net.ipv4.conf.default.forwarding=1" | sudo tee -a /etc/sysctl.conf
  - sudo sysctl -p
EOF

function wait_until_finished {
     wait_interval=15
     resource_id=$1
     resource_name=$(echo $resource_id | cut -d/ -f 9)
     echo -e "\e[1;37mWaiting for resource $resource_name to finish provisioning...\e[0m"
     start_time=`date +%s`
     state=$(az resource show --id $resource_id --query properties.provisioningState -o tsv)
     until [[ "$state" == "Succeeded" ]] || [[ "$state" == "Failed" ]] || [[ -z "$state" ]]
     do
        sleep $wait_interval
        state=$(az resource show --id $resource_id --query properties.provisioningState -o tsv)
     done
     if [[ -z "$state" ]]
     then
        echo -e "\e[1;31mSomething really bad happened...\e[0m"
     else
        run_time=$(expr `date +%s` - $start_time)
        ((minutes=${run_time}/60))
        ((seconds=${run_time}%60))
        echo -e "\e[1;35mResource $resource_name provisioning state is $state, wait time $minutes minutes and $seconds seconds\e[0m"
     fi
}

function first_ip(){
    subnet=$1
    IP=$(echo $subnet | cut -d/ -f 1)
    IP_HEX=$(printf '%.2X%.2X%.2X%.2X\n' `echo $IP | sed -e 's/\./ /g'`)
    NEXT_IP_HEX=$(printf %.8X `echo $(( 0x$IP_HEX + 1 ))`)
    NEXT_IP=$(printf '%d.%d.%d.%d\n' `echo $NEXT_IP_HEX | sed -r 's/(..)/0x\1 /g'`)
    echo "$NEXT_IP"
}

# resource groups
echo -e "\e[1;36mCreating $rg resource group ...\e[0m"
az group create -l $location1 -n $rg --tags $tag -o none

# hub1
echo -e "\e[1;36mCreating $hub1_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $hub1_vnet_name -l $location1 --address-prefixes $hub1_vnet_address --subnet-name $hub1_vm_subnet_name --subnet-prefixes $hub1_vm_subnet_address --tags $tag  -o none
az network vnet subnet create -g $rg -n GatewaySubnet --address-prefixes $hub1_gw_subnet_address --vnet-name $hub1_vnet_name -o none
az network vnet subnet create -g $rg -n $hub1_fw_subnet_name --address-prefixes $hub1_fw_subnet_address --vnet-name $hub1_vnet_name -o none

# hub1 vm nsg
echo -e "\e[1;36mCreating $hub1_vnet_name-vm-nsg NSG...\e[0m"
az network nsg create -g $rg -n $hub1_vnet_name-vm-nsg -l $location1 -o none
az network nsg rule create -g $rg -n AllowSSH --nsg-name $hub1_vnet_name-vm-nsg --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes $myip --source-port-ranges '*' -o none
az network vnet subnet update -g $rg -n $hub1_vm_subnet_name --vnet-name $hub1_vnet_name --nsg $hub1_vnet_name-vm-nsg -o none

# hub1 fw nsg
echo -e "\e[1;36mCreating $hub1_vnet_name-fw-nsg NSG...\e[0m"
az network nsg create -g $rg -n $hub1_vnet_name-fw-nsg -l $location1 -o none
az network nsg rule create -g $rg -n AllowSSH --nsg-name $hub1_vnet_name-fw-nsg --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes $myip --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowHTTP --nsg-name $hub1_vnet_name-fw-nsg --priority 1010 --access Allow --description AllowHTTP --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 80 --source-address-prefixes $myip --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowHTTPS --nsg-name $hub1_vnet_name-fw-nsg --priority 1020 --access Allow --description AllowHTTPS --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 443 --source-address-prefixes $myip --source-port-ranges '*' -o none
az network vnet subnet update -g $rg -n $hub1_fw_subnet_name --vnet-name $hub1_vnet_name --nsg $hub1_vnet_name-fw-nsg -o none

# vpn gateway
echo -e "\e[1;36mCreating $hub1_vnet_name-gw VNet...\e[0m"
az network public-ip create -g $rg -n "$hub1_vnet_name-gw-pubip0" -l $location1 --allocation-method Static --tags $tag -o none
az network public-ip create -g $rg -n "$hub1_vnet_name-gw-pubip1" -l $location1 --allocation-method Static --tags $tag -o none
az network vnet-gateway create -g $rg -n $hub1_vnet_name-gw -l $location1 --public-ip-addresses "$hub1_vnet_name-gw-pubip0" "$hub1_vnet_name-gw-pubip1" --vnet $hub1_vnet_name --gateway-type vpn --sku vpngw1 --vpn-type routebased --asn $hub1_gw_asn --tags $tag --no-wait 

# hub1 fw opnsense vm
echo -e "\e[1;36mCreating $hub1_vnet_name-fw VM...\e[0m"
az network public-ip create -g $rg -n "$hub1_vnet_name-fw" -l $location1 --allocation-method Static --sku Basic --tags $tag -o none
az network nic create -g $rg -n "$hub1_vnet_name-fw-wan" --subnet $hub1_fw_subnet_name --vnet-name $hub1_vnet_name --ip-forwarding true --private-ip-address 10.1.2.250 --public-ip-address "$hub1_vnet_name-fw" --tags $tag -o none
az vm create -g $rg -n $hub1_vnet_name-fw --image $hub1_fw_vm_image --nics "$hub1_vnet_name-fw-wan" --os-disk-name $hub1_vnet_name-fw --size Standard_B2als_v2 --admin-username $admin_username --generate-ssh-keys --tags $tag
# hub1 fw opnsense vm details:
hub1_fw_public_ip=$(az network public-ip show -g $rg -n "$hub1_vnet_name-fw" --query 'ipAddress' --output tsv) && echo $hub1_vnet_name-fw public ip: $hub1_fw_public_ip
hub1_fw_wan_private_ip=$(az network nic show -g $rg -n $hub1_vnet_name-fw-wan --query ipConfigurations[].privateIPAddress -o tsv) && echo $onprem1_vnet_name-gw wan private IP: $hub1_fw_wan_private_ip

# opnsense vm boot diagnostics
echo -e "\e[1;36mEnabling VM boot diagnostics for $hub1_vnet_name-fw...\e[0m"
az vm boot-diagnostics enable -g $rg -n $hub1_vnet_name-fw -o none

# configuring opnsense
echo -e "\e[1;36mConfiguring $hub1_vnet_name-fw...\e[0m"
config_file=~/config.xml
curl -o $config_file  https://raw.githubusercontent.com/wshamroukh/azure-site-to-site-s2s-vpn/main/s2s-bgp-nva-hub-spoke/config.xml
echo -e "\e[1;36mCopying configuration files to $vm_name and installing opnsense firewall...\e[0m"
scp -o StrictHostKeyChecking=no $opnsense_init_file $config_file $admin_username@$hub1_fw_public_ip:/home/$admin_username
ssh -o StrictHostKeyChecking=no $admin_username@$hub1_fw_public_ip "chmod +x /home/$admin_username/opnsense_init.sh && sh /home/$admin_username/opnsense_init.sh"
rm $opnsense_init_file $config_file

# onprem1
echo -e "\e[1;36mCreating $onprem1_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $onprem1_vnet_name -l $location1 --address-prefixes $onprem1_vnet_address --subnet-name $onprem1_vm_subnet_name --subnet-prefixes $onprem1_vm_subnet_address --tags $tag -o none
az network vnet subnet create -g $rg -n $onprem1_gw_subnet_name --address-prefixes $onprem1_gw_subnet_address --vnet-name $onprem1_vnet_name -o none

# onprem1-gw vm
echo -e "\e[1;36mCreating $onprem1_vnet_name-gw VM...\e[0m"
az network public-ip create -g $rg -n $onprem1_vnet_name-gw -l $location1 --allocation-method static --sku basic --tags $tag -o none
az network nic create -g $rg -n $onprem1_vnet_name-gw -l $location1 --vnet-name $onprem1_vnet_name --subnet $onprem1_gw_subnet_name --ip-forwarding true --public-ip-address $onprem1_vnet_name-gw --tags $tag -o none
az vm create -g $rg -n $onprem1_vnet_name-gw -l $location1 --image $vm_image --nics $onprem1_vnet_name-gw --os-disk-name "$onprem1_vnet_name-gw" --size $vm_size --admin-username $admin_username --generate-ssh-keys --custom-data $onprem_gw_cloudinit_file --tags $tag
# onprem1-gw vm details
onprem1_gw_pubip=$(az network public-ip show -g $rg -n $onprem1_vnet_name-gw --query ipAddress -o tsv) && echo $onprem1_vnet_name-gw: $onprem1_gw_pubip
onprem1_gw_private_ip=$(az network nic show -g $rg -n $onprem1_vnet_name-gw --query ipConfigurations[].privateIPAddress -o tsv) && echo $onprem1_vnet_name-gw private IP: $onprem1_gw_private_ip
onprem1_default_gw=$(first_ip $onprem1_gw_subnet_address) && echo $onprem1_vnet_name-gw external NIC default gateway IP: $onprem1_default_gw

# onprem1 local network gateway
echo -e "\e[1;36mCreating $onprem1_vnet_name-gw local network gateway...\e[0m"
az network local-gateway create -g $rg -n $onprem1_vnet_name-gw -l $location1 --gateway-ip-address $onprem1_gw_pubip --local-address-prefixes $onprem1_vnet_address --asn $onprem1_gw_asn --bgp-peering-address $onprem1_gw_private_ip  --tags $tag --no-wait

# onprem2
echo -e "\e[1;36mCreating $onprem2_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $onprem2_vnet_name -l $location2 --address-prefixes $onprem2_vnet_address --subnet-name $onprem2_vm_subnet_name --subnet-prefixes $onprem2_vm_subnet_address --tags $tag -o none
az network vnet subnet create -g $rg -n $onprem2_gw_subnet_name --address-prefixes $onprem2_gw_subnet_address --vnet-name $onprem2_vnet_name -o none

# onprem2-gw vm
echo -e "\e[1;36mCreating $onprem2_vnet_name-gw VM...\e[0m"
az network public-ip create -g $rg -n "$onprem2_vnet_name-gw" -l $location2 --allocation-method static --sku basic --tags $tag -o none
az network nic create -g $rg -n $onprem2_vnet_name-gw -l $location2 --vnet-name $onprem2_vnet_name --subnet $onprem2_gw_subnet_name --ip-forwarding true --public-ip-address "$onprem2_vnet_name-gw" --tags $tag -o none
az vm create -g $rg -n $onprem2_vnet_name-gw -l $location2 --image $vm_image --nics "$onprem2_vnet_name-gw" --os-disk-name "$onprem2_vnet_name-gw" --size $vm_size --admin-username $admin_username --generate-ssh-keys --custom-data $onprem_gw_cloudinit_file --tags $tag --no-wait -o none
# onprem2-gw vm details
onprem2_gw_pubip=$(az network public-ip show -g $rg -n $onprem2_vnet_name-gw --query ipAddress -o tsv) && echo $onprem2_vnet_name-gw public ip: $onprem2_gw_pubip
onprem2_gw_private_ip=$(az network nic show -g $rg -n $onprem2_vnet_name-gw --query ipConfigurations[].privateIPAddress -o tsv) && echo $onprem2_vnet_name-gw private ip: $onprem2_gw_private_ip
onprem2_default_gw=$(first_ip $onprem2_gw_subnet_address) && echo $onprem2_vnet_name-gw external NIC default gateway IP: $onprem2_default_gw

# onprem2 local network gateway
echo -e "\e[1;36mCreating $onprem2_vnet_name-gw local network gateway...\e[0m"
az network local-gateway create -g $rg -n $onprem2_vnet_name-gw -l $location1 --gateway-ip-address $onprem2_gw_pubip --local-address-prefixes $onprem2_vnet_address --asn $onprem2_gw_asn --bgp-peering-address $onprem2_gw_private_ip  --tags $tag --no-wait

# spoke1
echo -e "\e[1;36mCreating $spoke1_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $spoke1_vnet_name -l $location1 --address-prefixes $spoke1_vnet_address --subnet-name $spoke1_vm_subnet_name --subnet-prefixes $spoke1_vm_subnet_address --tags $tag -o none

# spoke2
echo -e "\e[1;36mCreating $spoke2_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $spoke2_vnet_name -l $location2 --address-prefixes $spoke2_vnet_address --subnet-name $spoke2_vm_subnet_name --subnet-prefixes $spoke2_vm_subnet_address --tags $tag -o none

# onprem1 vm nsg
echo -e "\e[1;36mCreating $onprem1_vnet_name-vm-nsg NSG...\e[0m"
az network nsg create -g $rg -n $onprem1_vnet_name-vm-nsg -l $location1 -o none
az network nsg rule create -g $rg -n AllowSSH --nsg-name $onprem1_vnet_name-vm-nsg --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowICMP --nsg-name $onprem1_vnet_name-vm-nsg --priority 1010 --access Allow --description AllowICMP --protocol Icmp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges '*' --source-address-prefixes '*' --source-port-ranges '*' -o none
az network vnet subnet update -g $rg -n $onprem1_vm_subnet_name --vnet-name $onprem1_vnet_name --nsg $onprem1_vnet_name-vm-nsg -o none

# onprem1 gw nsg
echo -e "\e[1;36mCreating $onprem1_vnet_name-gw-nsg NSG...\e[0m"
az network nsg create -g $rg -n $onprem1_vnet_name-gw-nsg -l $location1 -o none
az network nsg rule create -g $rg -n AllowSSHin --nsg-name $onprem1_vnet_name-gw-nsg --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowIKE --nsg-name $onprem1_vnet_name-gw-nsg --priority 1010 --access Allow --description AllowIKE --protocol Udp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 4500 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowIPSec --nsg-name $onprem1_vnet_name-gw-nsg --priority 1020 --access Allow --description AllowIPSec --protocol Udp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 500 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowICMPin --nsg-name $onprem1_vnet_name-gw-nsg --priority 1030 --access Allow --description AllowICMP --protocol Icmp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges '*' --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowSSHout --nsg-name $onprem1_vnet_name-gw-nsg --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Outbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowICMPout --nsg-name $onprem1_vnet_name-gw-nsg --priority 1010 --access Allow --description AllowICMP --protocol Icmp --direction Outbound --destination-address-prefixes '*' --destination-port-ranges '*' --source-address-prefixes '*' --source-port-ranges '*' -o none
az network vnet subnet update -g $rg -n $onprem1_gw_subnet_name --vnet-name $onprem1_vnet_name --nsg $onprem1_vnet_name-gw-nsg -o none

# onprem2 vm nsg
echo -e "\e[1;36mCreating $onprem2_vnet_name-vm-nsg NSG...\e[0m"
az network nsg create -g $rg -n $onprem2_vnet_name-vm-nsg -l $location2 -o none
az network nsg rule create -g $rg -n AllowSSH --nsg-name $onprem2_vnet_name-vm-nsg --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowICMP --nsg-name $onprem2_vnet_name-vm-nsg --priority 1010 --access Allow --description AllowICMP --protocol Icmp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges '*' --source-address-prefixes '*' --source-port-ranges '*' -o none
az network vnet subnet update -g $rg -n $onprem2_vm_subnet_name --vnet-name $onprem2_vnet_name --nsg $onprem2_vnet_name-vm-nsg -o none

# onprem2 gw nsg
echo -e "\e[1;36mCreating $onprem2_vnet_name-gw-nsg NSG...\e[0m"
az network nsg create -g $rg -n $onprem2_vnet_name-gw-nsg -l $location2 -o none
az network nsg rule create -g $rg -n AllowSSHin --nsg-name $onprem2_vnet_name-gw-nsg --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowIKE --nsg-name $onprem2_vnet_name-gw-nsg --priority 1010 --access Allow --description AllowIKE --protocol Udp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 4500 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowIPSec --nsg-name $onprem2_vnet_name-gw-nsg --priority 1020 --access Allow --description AllowIPSec --protocol Udp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 500 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowICMPin --nsg-name $onprem2_vnet_name-gw-nsg --priority 1030 --access Allow --description AllowICMP --protocol Icmp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges '*' --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowSSHout --nsg-name $onprem2_vnet_name-gw-nsg --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Outbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowICMPout --nsg-name $onprem2_vnet_name-gw-nsg --priority 1010 --access Allow --description AllowICMP --protocol Icmp --direction Outbound --destination-address-prefixes '*' --destination-port-ranges '*' --source-address-prefixes '*' --source-port-ranges '*' -o none
az network vnet subnet update -g $rg -n $onprem2_gw_subnet_name --vnet-name $onprem2_vnet_name --nsg $onprem2_vnet_name-gw-nsg -o none

# spoke1 vm nsg
echo -e "\e[1;36mCreating $spoke1_vnet_name-vm-nsg NSG...\e[0m"
az network nsg create -g $rg -n $spoke1_vnet_name-vm-nsg -l $location1 -o none
az network nsg rule create -g $rg -n AllowSSH --nsg-name $spoke1_vnet_name-vm-nsg --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network vnet subnet update -g $rg -n $spoke1_vm_subnet_name --vnet-name $spoke1_vnet_name --nsg $spoke1_vnet_name-vm-nsg -o none

# spoke2 vm nsg
echo -e "\e[1;36mCreating $spoke2_vnet_name-vm-nsg NSG...\e[0m"
az network nsg create -g $rg -n $spoke2_vnet_name-vm-nsg -l $location2 -o none
az network nsg rule create -g $rg -n AllowSSH --nsg-name $spoke2_vnet_name-vm-nsg --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network vnet subnet update -g $rg -n $spoke2_vm_subnet_name --vnet-name $spoke2_vnet_name --nsg $spoke2_vnet_name-vm-nsg -o none

# hub1 vm
echo -e "\e[1;36mCreating $hub1_vnet_name VM...\e[0m"
az network nic create -g $rg -n $hub1_vnet_name -l $location1 --vnet-name $hub1_vnet_name --subnet $hub1_vm_subnet_name --tags $tag -o none
az vm create -g $rg -n $hub1_vnet_name -l $location1 --image $vm_image --nics "$hub1_vnet_name" --os-disk-name "$hub1_vnet_name" --size $vm_size --admin-username $admin_username --generate-ssh-keys --tags $tag --no-wait
hub1_vm_ip=$(az network nic show -g $rg -n $hub1_vnet_name --query ipConfigurations[].privateIPAddress -o tsv) && echo $hub1_vnet_name vm private ip: $hub1_vm_ip

# spoke1 vm
echo -e "\e[1;36mCreating $spoke1_vnet_name VM...\e[0m"
az network nic create -g $rg -n "$spoke1_vnet_name" -l $location1 --vnet-name $spoke1_vnet_name --subnet $spoke1_vm_subnet_name --tags $tag -o none
az vm create -g $rg -n $spoke1_vnet_name -l $location1 --image $vm_image --nics "$spoke1_vnet_name" --os-disk-name "$spoke1_vnet_name" --size $vm_size --admin-username $admin_username --generate-ssh-keys --tags $tag --no-wait
spoke1_vm_ip=$(az network nic show -g $rg -n $spoke1_vnet_name --query ipConfigurations[].privateIPAddress -o tsv) && echo $spoke1_vnet_name vm private ip: $spoke1_vm_ip

# spoke2 vm
echo -e "\e[1;36mCreating $spoke2_vnet_name VM...\e[0m"
az network nic create -g $rg -n "$spoke2_vnet_name" -l $location2 --vnet-name $spoke2_vnet_name --subnet $spoke2_vm_subnet_name --tags $tag -o none
az vm create -g $rg -n $spoke2_vnet_name -l $location2 --image $vm_image --nics "$spoke2_vnet_name" --os-disk-name "$spoke2_vnet_name" --size $vm_size --admin-username $admin_username --generate-ssh-keys --tags $tag --no-wait
spoke2_vm_ip=$(az network nic show -g $rg -n $spoke2_vnet_name --query ipConfigurations[].privateIPAddress -o tsv) && echo $spoke2_vnet_name vm private ip: $spoke2_vm_ip

# onprem1 vm
echo -e "\e[1;36mCreating $onprem1_vnet_name VM...\e[0m"
az network nic create -g $rg -n "$onprem1_vnet_name" -l $location1 --vnet-name $onprem1_vnet_name --subnet $onprem1_vm_subnet_name --tags $tag -o none
az vm create -g $rg -n $onprem1_vnet_name -l $location1 --image $vm_image --nics "$onprem1_vnet_name" --os-disk-name "$onprem1_vnet_name" --size $vm_size --admin-username $admin_username --generate-ssh-keys --tags $tag --no-wait
onprem1_vm_ip=$(az network nic show -g $rg -n $onprem1_vnet_name --query ipConfigurations[].privateIPAddress -o tsv) && echo $onprem1_vnet_name vm private ip: $onprem1_vm_ip

# onprem2 vm
echo -e "\e[1;36mCreating $onprem2_vnet_name VM...\e[0m"
az network nic create -g $rg -n "$onprem2_vnet_name" -l $location2 --vnet-name $onprem2_vnet_name --subnet $onprem2_vm_subnet_name --tags $tag -o none
az vm create -g $rg -n $onprem2_vnet_name -l $location2 --image $vm_image --nics "$onprem2_vnet_name" --os-disk-name "$onprem2_vnet_name" --size $vm_size --admin-username $admin_username --generate-ssh-keys --tags $tag --no-wait
onprem2_vm_ip=$(az network nic show -g $rg -n $onprem2_vnet_name --query ipConfigurations[].privateIPAddress -o tsv) && echo $onprem2_vnet_name vm private ip: $onprem2_vm_ip

# onprem1 route table
echo -e "\e[1;36mCreating $onprem1_vnet_name route table...\e[0m"
az network route-table create -g $rg -n $onprem1_vnet_name -l $location1 --tags $tag -o none
az network route-table route create -g $rg -n to-$hub1_vnet_name --address-prefix $hub1_vnet_address --next-hop-type virtualappliance --route-table-name $onprem1_vnet_name --next-hop-ip-address $onprem1_gw_private_ip -o none
az network route-table route create -g $rg -n to-$spoke1_vnet_name --address-prefix $spoke1_vnet_address --next-hop-type virtualappliance --route-table-name $onprem1_vnet_name --next-hop-ip-address $onprem1_gw_private_ip -o none
az network route-table route create -g $rg -n to-$spoke2_vnet_name --address-prefix $spoke2_vnet_address --next-hop-type virtualappliance --route-table-name $onprem1_vnet_name --next-hop-ip-address $onprem1_gw_private_ip -o none
az network route-table route create -g $rg -n to-$onprem2_vnet_name --address-prefix $onprem2_vnet_address --next-hop-type virtualappliance --route-table-name $onprem1_vnet_name --next-hop-ip-address $onprem1_gw_private_ip -o none
az network vnet subnet update -g $rg --vnet-name $onprem1_vnet_name -n $onprem1_vm_subnet_name --route-table $onprem1_vnet_name -o none

# onprem2 route table
echo -e "\e[1;36mCreating $onprem2_vnet_name route table...\e[0m"
az network route-table create -g $rg -n $onprem2_vnet_name -l $location2 --tags $tag -o none
az network route-table route create -g $rg -n to-$hub1_vnet_name --address-prefix $hub1_vnet_address --next-hop-type virtualappliance --route-table-name $onprem2_vnet_name --next-hop-ip-address $onprem2_gw_private_ip -o none
az network route-table route create -g $rg -n to-$spoke1_vnet_name --address-prefix $spoke1_vnet_address --next-hop-type virtualappliance --route-table-name $onprem2_vnet_name --next-hop-ip-address $onprem2_gw_private_ip -o none
az network route-table route create -g $rg -n to-$spoke2_vnet_name --address-prefix $spoke2_vnet_address --next-hop-type virtualappliance --route-table-name $onprem2_vnet_name --next-hop-ip-address $onprem2_gw_private_ip -o none
az network route-table route create -g $rg -n to-$onprem1_vnet_name --address-prefix $onprem1_vnet_address --next-hop-type virtualappliance --route-table-name $onprem2_vnet_name --next-hop-ip-address $onprem2_gw_private_ip -o none
az network vnet subnet update -g $rg -n $onprem2_vm_subnet_name --vnet-name $onprem2_vnet_name --route-table $onprem2_vnet_name -o none

# waiting on hub1 gw to finish deployment
hub1_gw_id=$(az network vnet-gateway show -n $hub1_vnet_name-gw -g $rg --query 'id' -o tsv)
wait_until_finished $hub1_gw_id

# get azure vpn gw details
hub1_gw_pubip0=$(az network vnet-gateway show -g $rg -n $hub1_vnet_name-gw --query 'bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]' -o tsv) && echo $hub1_vnet_name-gw public ip0: $hub1_gw_pubip0
hub1_gw_pubip1=$(az network vnet-gateway show -g $rg -n $hub1_vnet_name-gw --query 'bgpSettings.bgpPeeringAddresses[1].tunnelIpAddresses[0]' -o tsv) && echo $hub1_vnet_name-gw public ip1: $hub1_gw_pubip1
hub1_gw_bgp_ip0=$(az network vnet-gateway show -g $rg -n $hub1_vnet_name-gw --query 'bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]' -o tsv) && echo $hub1_vnet_name-gw bgp ip0: $hub1_gw_bgp_ip0
hub1_gw_bgp_ip1=$(az network vnet-gateway show -g $rg -n $hub1_vnet_name-gw --query 'bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]' -o tsv) && echo $hub1_vnet_name-gw bgp ip1: $hub1_gw_bgp_ip1
hub1_gw_asn=$(az network vnet-gateway show -g $rg -n $hub1_vnet_name-gw --query bgpSettings.asn -o tsv) && echo  $hub1_vnet_name-gw asn: $hub1_gw_asn

# spoke1-to-hub1 vnet peering
echo -e "\e[1;36mCreating VNet Peering between $hub1_vnet_name and $spoke1_vnet_name...\e[0m"
az network vnet peering create -g $rg -n $hub1_vnet_name-peering --remote-vnet $hub1_vnet_name --vnet-name $spoke1_vnet_name --allow-vnet-access --use-remote-gateway -o none
# hub1-$spoke1_vnet_name vnet peering
az network vnet peering create -g $rg -n $spoke1_vnet_name-peering --remote-vnet $spoke1_vnet_name --vnet-name $hub1_vnet_name --allow-vnet-access --allow-gateway-transit --allow-forwarded-traffic -o none
# spoke2-to-hub1 vnet peering
echo -e "\e[1;36mCreating VNet Peering between $hub1_vnet_name and $spoke2_vnet_name...\e[0m"
az network vnet peering create -g $rg -n $hub1_vnet_name-peering --remote-vnet $hub1_vnet_name --vnet-name $spoke2_vnet_name --allow-vnet-access --use-remote-gateway -o none
# hub1-$spoke2_vnet_name vnet peering
az network vnet peering create -g $rg -n $spoke2_vnet_name-peering --remote-vnet $spoke2_vnet_name --vnet-name $hub1_vnet_name --allow-vnet-access --allow-gateway-transit --allow-forwarded-traffic -o none

# onprem1 s2s vpn connection
echo -e "\e[1;36mCreating $hub1_vnet_name-to-$onprem1_vnet_name-s2s-connection...\e[0m"
az network vpn-connection create -g $rg -n $hub1_vnet_name-gw-to-$onprem1_vnet_name-s2s-connection --vnet-gateway1 $hub1_vnet_name-gw --shared-key $psk --local-gateway2 $onprem1_vnet_name-gw --enable-bgp --tags $tag -o none

# onprem2 s2s vpn connection
echo -e "\e[1;36mCreating $hub1_vnet_name-to-$onprem2_vnet_name-s2s-connection...\e[0m"
az network vpn-connection create -g $rg -n $hub1_vnet_name-gw-to-$onprem2_vnet_name-s2s-connection --vnet-gateway1 $hub1_vnet_name-gw --shared-key $psk --local-gateway2 $onprem2_vnet_name-gw --enable-bgp --tags $tag -o none

################################
# onprem1 Gateway Configuration #
################################
echo -e "\e[1;36mCopying confiuration files to $onprem1_vnet_name-gw VM\e[0m"
# ipsec.secrets
psk_file=~/ipsec.secrets
cat <<EOF > $psk_file
$onprem1_gw_pubip $hub1_gw_pubip0 : PSK $psk
$onprem1_gw_pubip $hub1_gw_pubip1 : PSK $psk
EOF

# ipsec.conf
ipsec_file=~/ipsec.conf
cat <<EOF > $ipsec_file
conn %default
         # Authentication Method : Pre-Shared Key
         leftauth=psk
         rightauth=psk
         ike=aes256-sha1-modp1024!
         ikelifetime=28800s
         # Phase 1 Negotiation Mode : main
         aggressive=no
         esp=aes256-sha1!
         lifetime=3600s
         keylife=3600s
         type=tunnel
         dpddelay=10s
         dpdtimeout=30s
         keyexchange=ikev2
         rekey=yes
         reauth=no
         dpdaction=restart
         closeaction=restart
         leftsubnet=0.0.0.0/0,::/0
         rightsubnet=0.0.0.0/0,::/0
         leftupdown=/etc/strongswan.d/ipsec-vti.sh
         installpolicy=yes
         compress=no
         mobike=no
conn $hub1_vnet_name-gw0
         # onprem1 Gateway Private IP Address :
         left=$onprem1_gw_private_ip
         # onprem1 Gateway Public IP Address :
         leftid=$onprem1_gw_pubip
         # Azure VPN Gateway Public IP address :
         right=$hub1_gw_pubip0
         rightid=$hub1_gw_pubip0
         auto=start
         # unique number per IPSEC Tunnel eg. 100, 101 etc
         mark=101
conn $hub1_vnet_name-gw1
         # onprem1 Gateway Private IP Address :
         left=$onprem1_gw_private_ip
         # onprem1 Gateway Public IP Address :
         leftid=$onprem1_gw_pubip
         # Azure VPN Gateway Public IP address :
         right=$hub1_gw_pubip1
         rightid=$hub1_gw_pubip1
         auto=start
         # unique number per IPSEC Tunnel eg. 100, 101 etc
         mark=102
EOF

# ipsec-vti.sh
ipsec_vti_file=~/ipsec-vti.sh
tee -a $ipsec_vti_file > /dev/null <<'EOT'
#!/bin/bash

#
# /etc/strongswan.d/ipsec-vti.sh
#

IP=$(which ip)
IPTABLES=$(which iptables)
PLUTO_MARK_OUT_ARR=(${PLUTO_MARK_OUT//// })
PLUTO_MARK_IN_ARR=(${PLUTO_MARK_IN//// })
case "$PLUTO_CONNECTION" in
  $hub1_vnet_name-gw0)
    VTI_INTERFACE=vti0
    VTI_LOCALADDR=$onprem1_gw_vti0/32
    VTI_REMOTEADDR=$hub1_gw_bgp_ip0/32
    ;;
   $hub1_vnet_name-gw1)
    VTI_INTERFACE=vti1
    VTI_LOCALADDR=$onprem1_gw_vti1/32
    VTI_REMOTEADDR=$hub1_gw_bgp_ip1/32
    ;;
esac
case "${PLUTO_VERB}" in
    up-client)
        $IP link add ${VTI_INTERFACE} type vti local ${PLUTO_ME} remote ${PLUTO_PEER} okey ${PLUTO_MARK_OUT_ARR[0]} ikey ${PLUTO_MARK_IN_ARR[0]}
        sysctl -w net.ipv4.conf.${VTI_INTERFACE}.disable_policy=1
        sysctl -w net.ipv4.conf.${VTI_INTERFACE}.rp_filter=2 || sysctl -w net.ipv4.conf.${VTI_INTERFACE}.rp_filter=0
        $IP addr add ${VTI_LOCALADDR} remote ${VTI_REMOTEADDR} dev ${VTI_INTERFACE}
        $IP link set ${VTI_INTERFACE} up mtu 1350
        $IPTABLES -t mangle -I FORWARD -o ${VTI_INTERFACE} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        $IPTABLES -t mangle -I INPUT -p esp -s ${PLUTO_PEER} -d ${PLUTO_ME} -j MARK --set-xmark ${PLUTO_MARK_IN}
        $IP route flush table 220
        ;;
    down-client)
        $IP link del ${VTI_INTERFACE}
        $IPTABLES -t mangle -D FORWARD -o ${VTI_INTERFACE} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        $IPTABLES -t mangle -D INPUT -p esp -s ${PLUTO_PEER} -d ${PLUTO_ME} -j MARK --set-xmark ${PLUTO_MARK_IN}
        ;;
esac

# Enable IPv4 forwarding
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.eth0.disable_xfrm=1
sysctl -w net.ipv4.conf.eth0.disable_policy=1
EOT

sed -i "/\$onprem1_gw_vti0/ s//$onprem1_gw_vti0/" $ipsec_vti_file
sed -i "/\$onprem1_gw_vti1/ s//$onprem1_gw_vti1/" $ipsec_vti_file
sed -i "/\$hub1_gw_bgp_ip0/ s//$hub1_gw_bgp_ip0/" $ipsec_vti_file
sed -i "/\$hub1_gw_bgp_ip1/ s//$hub1_gw_bgp_ip1/" $ipsec_vti_file
sed -i "/\$hub1_vnet_name-gw0/ s//$hub1_vnet_name-gw0/" $ipsec_vti_file
sed -i "/\$hub1_vnet_name-gw1/ s//$hub1_vnet_name-gw1/" $ipsec_vti_file

# frr.conf
frr_conf_file=~/frr.conf
cat <<EOF > $frr_conf_file
frr version 10.1
frr defaults traditional
hostname $onprem1_vnet_name-gw
log syslog informational
no ipv6 forwarding
service integrated-vtysh-config
!
ip route $hub1_gw_bgp_ip0/32 $onprem1_default_gw
ip route $hub1_gw_bgp_ip1/32 $onprem1_default_gw
ip route $onprem1_vnet_address $onprem1_default_gw
!
router bgp $onprem1_gw_asn
 bgp router-id $onprem1_gw_private_ip
 no bgp ebgp-requires-policy
 neighbor $hub1_gw_bgp_ip0 remote-as $hub1_gw_asn
 neighbor $hub1_gw_bgp_ip0 description $hub1_vnet_name-gw-0
 neighbor $hub1_gw_bgp_ip0 ebgp-multihop 2
 neighbor $hub1_gw_bgp_ip1 remote-as $hub1_gw_asn
 neighbor $hub1_gw_bgp_ip1 description $hub1_vnet_name-gw-1
 neighbor $hub1_gw_bgp_ip1 ebgp-multihop 2
 !
 address-family ipv4 unicast
  network $onprem1_vnet_address
  neighbor $hub1_gw_bgp_ip0 soft-reconfiguration inbound
  neighbor $hub1_gw_bgp_ip1 soft-reconfiguration inbound
 exit-address-family
exit
!
EOF

# Copy files to site1 gw and restart ipsec daemon
echo -e "\e[1;36mConfiguring S2S VPN connection on $onprem1_vnet_name-gw VM....\e[0m"
scp -o StrictHostKeyChecking=no $psk_file $ipsec_file $ipsec_vti_file $frr_conf_file $onprem1_gw_pubip:/home/$admin_username
scp -o StrictHostKeyChecking=no ~/.ssh/* $onprem1_gw_pubip:/home/$admin_username/.ssh/
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo mv /home/$admin_username/ipsec.* /etc/ && sudo mv /home/$admin_username/ipsec-vti.sh /etc/strongswan.d/ && chmod +x /etc/strongswan.d/ipsec-vti.sh && sudo mv /home/$admin_username/frr.conf /etc/frr/ && sudo service frr restart && sudo ipsec restart"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo ipsec stop && sudo ipsec start && sudo ipsec status && ip a"

# deleting files from local session
rm $psk_file $ipsec_file $ipsec_vti_file $frr_conf_file $onprem_gw_cloudinit_file

################################
# onprem2 Gateway Configuration #
################################
echo -e "\e[1;36mCopying confiuration files to $onprem2_vnet_name-gw VM\e[0m"
# ipsec.secrets
psk_file=~/ipsec.secrets
cat <<EOF > $psk_file
$onprem2_gw_pubip $hub1_gw_pubip0 : PSK $psk
$onprem2_gw_pubip $hub1_gw_pubip1 : PSK $psk
EOF

# ipsec.conf
ipsec_file=~/ipsec.conf
cat <<EOF > $ipsec_file
conn %default
         # Authentication Method : Pre-Shared Key
         leftauth=psk
         rightauth=psk
         ike=aes256-sha1-modp1024!
         ikelifetime=28800s
         # Phase 1 Negotiation Mode : main
         aggressive=no
         esp=aes256-sha1!
         lifetime=3600s
         keylife=3600s
         type=tunnel
         dpddelay=10s
         dpdtimeout=30s
         keyexchange=ikev2
         rekey=yes
         reauth=no
         dpdaction=restart
         closeaction=restart
         leftsubnet=0.0.0.0/0,::/0
         rightsubnet=0.0.0.0/0,::/0
         leftupdown=/etc/strongswan.d/ipsec-vti.sh
         installpolicy=yes
         compress=no
         mobike=no
conn $hub1_vnet_name-gw0
         # onprem2 Gateway Private IP Address :
         left=$onprem2_gw_private_ip
         # onprem2 Gateway Public IP Address :
         leftid=$onprem2_gw_pubip
         # Azure VPN Gateway Public IP address :
         right=$hub1_gw_pubip0
         rightid=$hub1_gw_pubip0
         auto=start
         # unique number per IPSEC Tunnel eg. 100, 101 etc
         mark=101
conn $hub1_vnet_name-gw1
         # onprem2 Gateway Private IP Address :
         left=$onprem2_gw_private_ip
         # onprem2 Gateway Public IP Address :
         leftid=$onprem2_gw_pubip
         # Azure VPN Gateway Public IP address :
         right=$hub1_gw_pubip1
         rightid=$hub1_gw_pubip1
         auto=start
         # unique number per IPSEC Tunnel eg. 100, 101 etc
         mark=102
EOF

# ipsec-vti.sh
ipsec_vti_file=~/ipsec-vti.sh
tee -a $ipsec_vti_file > /dev/null <<'EOT'
#!/bin/bash

#
# /etc/strongswan.d/ipsec-vti.sh
#

IP=$(which ip)
IPTABLES=$(which iptables)
PLUTO_MARK_OUT_ARR=(${PLUTO_MARK_OUT//// })
PLUTO_MARK_IN_ARR=(${PLUTO_MARK_IN//// })
case "$PLUTO_CONNECTION" in
  $hub1_vnet_name-gw0)
    VTI_INTERFACE=vti0
    VTI_LOCALADDR=$onprem2_gw_vti0/32
    VTI_REMOTEADDR=$hub1_gw_bgp_ip0/32
    ;;
   $hub1_vnet_name-gw1)
    VTI_INTERFACE=vti1
    VTI_LOCALADDR=$onprem2_gw_vti1/32
    VTI_REMOTEADDR=$hub1_gw_bgp_ip1/32
    ;;
esac
case "${PLUTO_VERB}" in
    up-client)
        $IP link add ${VTI_INTERFACE} type vti local ${PLUTO_ME} remote ${PLUTO_PEER} okey ${PLUTO_MARK_OUT_ARR[0]} ikey ${PLUTO_MARK_IN_ARR[0]}
        sysctl -w net.ipv4.conf.${VTI_INTERFACE}.disable_policy=1
        sysctl -w net.ipv4.conf.${VTI_INTERFACE}.rp_filter=2 || sysctl -w net.ipv4.conf.${VTI_INTERFACE}.rp_filter=0
        $IP addr add ${VTI_LOCALADDR} remote ${VTI_REMOTEADDR} dev ${VTI_INTERFACE}
        $IP link set ${VTI_INTERFACE} up mtu 1350
        $IPTABLES -t mangle -I FORWARD -o ${VTI_INTERFACE} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        $IPTABLES -t mangle -I INPUT -p esp -s ${PLUTO_PEER} -d ${PLUTO_ME} -j MARK --set-xmark ${PLUTO_MARK_IN}
        $IP route flush table 220
        ;;
    down-client)
        $IP link del ${VTI_INTERFACE}
        $IPTABLES -t mangle -D FORWARD -o ${VTI_INTERFACE} -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        $IPTABLES -t mangle -D INPUT -p esp -s ${PLUTO_PEER} -d ${PLUTO_ME} -j MARK --set-xmark ${PLUTO_MARK_IN}
        ;;
esac

# Enable IPv4 forwarding
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.eth0.disable_xfrm=1
sysctl -w net.ipv4.conf.eth0.disable_policy=1
EOT

sed -i "/\$onprem2_gw_vti0/ s//$onprem2_gw_vti0/" $ipsec_vti_file
sed -i "/\$onprem2_gw_vti1/ s//$onprem2_gw_vti1/" $ipsec_vti_file
sed -i "/\$hub1_gw_bgp_ip0/ s//$hub1_gw_bgp_ip0/" $ipsec_vti_file
sed -i "/\$hub1_gw_bgp_ip1/ s//$hub1_gw_bgp_ip1/" $ipsec_vti_file
sed -i "/\$hub1_vnet_name-gw0/ s//$hub1_vnet_name-gw0/" $ipsec_vti_file
sed -i "/\$hub1_vnet_name-gw1/ s//$hub1_vnet_name-gw1/" $ipsec_vti_file

# frr.conf
frr_conf_file=~/frr.conf
cat <<EOF > $frr_conf_file
frr version 10.1
frr defaults traditional
hostname $onprem2_vnet_name-gw
log syslog informational
no ipv6 forwarding
service integrated-vtysh-config
!
ip route $hub1_gw_bgp_ip0/32 $onprem2_default_gw
ip route $hub1_gw_bgp_ip1/32 $onprem2_default_gw
ip route $onprem2_vnet_address $onprem2_default_gw
!
router bgp $onprem2_gw_asn
 bgp router-id $onprem2_gw_private_ip
 no bgp ebgp-requires-policy
 neighbor $hub1_gw_bgp_ip0 remote-as $hub1_gw_asn
 neighbor $hub1_gw_bgp_ip0 description $hub1_vnet_name-gw-0
 neighbor $hub1_gw_bgp_ip0 ebgp-multihop 2
 neighbor $hub1_gw_bgp_ip1 remote-as $hub1_gw_asn
 neighbor $hub1_gw_bgp_ip1 description $hub1_vnet_name-gw-1
 neighbor $hub1_gw_bgp_ip1 ebgp-multihop 2
 !
 address-family ipv4 unicast
  network $onprem2_vnet_address
  neighbor $hub1_gw_bgp_ip0 soft-reconfiguration inbound
  neighbor $hub1_gw_bgp_ip1 soft-reconfiguration inbound
 exit-address-family
exit
!
EOF

# Copy files to site1 gw and restart ipsec daemon
echo -e "\e[1;36mConfiguring S2S VPN connection on $onprem2_vnet_name-gw....\e[0m"
scp -o StrictHostKeyChecking=no $psk_file $ipsec_file $ipsec_vti_file $frr_conf_file $onprem2_gw_pubip:/home/$admin_username
scp -o StrictHostKeyChecking=no ~/.ssh/* $onprem2_gw_pubip:/home/$admin_username/.ssh/
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo mv /home/$admin_username/ipsec.* /etc/ && sudo mv /home/$admin_username/ipsec-vti.sh /etc/strongswan.d/ && chmod +x /etc/strongswan.d/ipsec-vti.sh && sudo mv /home/$admin_username/frr.conf /etc/frr/ && sudo service frr restart && sudo ipsec restart"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo ipsec restart"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo ipsec stop && sudo ipsec start && sudo ipsec status && ip a"

# deleting files from local session
rm $psk_file $ipsec_file $ipsec_vti_file $frr_conf_file

#############################################################
# Diagnosis before directing all the traffic to AZ Firewall #
#############################################################
echo -e "\e[1;36mChecking BGP routing on $onprem1_vnet_name-gw gateway VM...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo ipsec stop && sudo ipsec start && sudo ipsec status && ip a"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo vtysh -c 'show bgp summary'"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo vtysh -c 'show ip bgp'"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo vtysh -c 'show ip route'"

echo -e "\e[1;36mChecking connectivity from $onprem1_vnet_name-gw gateway VM to the rest of network topology...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "ping -c 3 $hub1_vm_ip"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "ping -c 3 $spoke1_vm_ip"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "ping -c 3 $spoke2_vm_ip"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "ping -c 3 $onprem2_vm_ip"

echo -e "\e[1;36mChecking BGP routing on $onprem2_vnet_name-gw gateway vm...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo ipsec status && ip a"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo vtysh -c 'show bgp summary'"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo vtysh -c 'show ip bgp'"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo vtysh -c 'show ip route'"

echo -e "\e[1;36mChecking connectivity from $onprem2_vnet_name-gw gateway VM to the rest of network topology...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "ping -c 3 $hub1_vm_ip"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "ping -c 3 $spoke1_vm_ip"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "ping -c 3 $spoke2_vm_ip"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "ping -c 3 $onprem1_vm_ip"

echo -e "\e[1;36mLearned routes on $hub1_vnet_name-gw VNet gateway...\e[0m"
az network vnet-gateway list-learned-routes -g $rg -n $hub1_vnet_name-gw -o table
echo -e "\e[1;36mAdvertised routes on $hub1_vnet_name-gw VNet gateway to $onprem1_vnet_name-gw gateway...\e[0m"
az network vnet-gateway list-advertised-routes -g $rg -n $hub1_vnet_name-gw --peer $onprem1_gw_private_ip -o table
echo -e "\e[1;36mAdvertised routes on $hub1_vnet_name-gw VNet gateway to $onprem2_vnet_name-gw gateway...\e[0m"
az network vnet-gateway list-advertised-routes -g $rg -n $hub1_vnet_name-gw --peer $onprem2_gw_private_ip -o table

echo -e "\e[1;36mEffective route table on $hub1_vnet_name VM...\e[0m"
az network nic show-effective-route-table -g $rg -n $hub1_vnet_name -o table
echo -e "\e[1;36mEffective route table on $spoke1_vnet_name VM...\e[0m"
az network nic show-effective-route-table -g $rg -n $spoke1_vnet_name -o table
echo -e "\e[1;36mEffective route table on $spoke2_vnet_name VM...\e[0m"
az network nic show-effective-route-table -g $rg -n $spoke2_vnet_name -o table

##############################################
### Sending all traffic to the hub1 firewall #
##############################################

# gateway subnet route table
echo -e "\e[1;36mCreating $hub1_vnet_name-gw route table....\e[0m"
az network route-table create -g $rg -n $hub1_vnet_name-gw -l $location1 --disable-bgp-route-propagation false --tags $tag -o none
az network route-table route create -g $rg -n $hub1_vnet_name --address-prefix $hub1_vnet_address --next-hop-type virtualappliance --route-table-name $hub1_vnet_name-gw --next-hop-ip-address $hub1_fw_lan_private_ip -o none
az network route-table route create -g $rg -n $spoke1_vnet_name --address-prefix $spoke1_vnet_address --next-hop-type virtualappliance --route-table-name $hub1_vnet_name-gw --next-hop-ip-address $hub1_fw_lan_private_ip -o none
az network route-table route create -g $rg -n $spoke2_vnet_name --address-prefix $spoke2_vnet_address --next-hop-type virtualappliance --route-table-name $hub1_vnet_name-gw --next-hop-ip-address $hub1_fw_lan_private_ip -o none
az network vnet subnet update -g $rg -n GatewaySubnet --vnet-name $hub1_vnet_name --route-table $hub1_vnet_name-gw -o none

# # hub1 vm route table
echo -e "\e[1;36mCreating $hub1_vnet_name-vm route table....\e[0m"
az network route-table create -g $rg -n $hub1_vnet_name-vm -l $location1 --disable-bgp-route-propagation true --tags $tag -o none
az network route-table route create -g $rg -n to-default0 --address-prefix $default0 --next-hop-type virtualappliance --route-table-name $hub1_vnet_name-vm --next-hop-ip-address $hub1_fw_lan_private_ip -o none
az network route-table route create -g $rg -n to-default1 --address-prefix $default1 --next-hop-type virtualappliance --route-table-name $hub1_vnet_name-vm --next-hop-ip-address $hub1_fw_lan_private_ip -o none
az network vnet subnet update -g $rg -n $hub1_vm_subnet_name --vnet-name $hub1_vnet_name --route-table $hub1_vnet_name-vm -o none

# spoke1 route table
echo -e "\e[1;36mCreating $spoke1_vnet_name route table....\e[0m"
az network route-table create -g $rg -n $spoke1_vnet_name -l $location1 --disable-bgp-route-propagation true --tags $tag -o none
az network route-table route create -g $rg -n to-default0 --address-prefix $default0 --next-hop-type virtualappliance --route-table-name $spoke1_vnet_name --next-hop-ip-address $hub1_fw_lan_private_ip -o none
az network route-table route create -g $rg -n to-default1 --address-prefix $default1 --next-hop-type virtualappliance --route-table-name $spoke1_vnet_name --next-hop-ip-address $hub1_fw_lan_private_ip -o none
az network vnet subnet update -g $rg -n $spoke1_vm_subnet_name --vnet-name $spoke1_vnet_name --route-table $spoke1_vnet_name -o none

# spoke2 route table
echo -e "\e[1;36mCreating $spoke2_vnet_name route table....\e[0m"
az network route-table create -n $spoke2_vnet_name -g $rg -l $location2 --disable-bgp-route-propagation true --tags $tag -o none
az network route-table route create -g $rg -n to-default0 --address-prefix $default0 --next-hop-type virtualappliance --route-table-name $spoke2_vnet_name --next-hop-ip-address $hub1_fw_lan_private_ip -o none
az network route-table route create -g $rg -n to-default1 --address-prefix $default1 --next-hop-type virtualappliance --route-table-name $spoke2_vnet_name --next-hop-ip-address $hub1_fw_lan_private_ip -o none
az network vnet subnet update -g $rg -n $spoke2_vm_subnet_name --vnet-name $spoke2_vnet_name --route-table $spoke2_vnet_name -o none


##############################################################
# Diagnosis after directing the traffic to opnsense Firewall #
##############################################################
echo -e "\e[1;36mChecking BGP routing on $onprem1_vnet_name-gw gateway vm...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo ipsec status"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo vtysh -c 'show bgp summary'"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo vtysh -c 'show ip bgp'"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo vtysh -c 'show ip route'"

echo -e "\e[1;36mChecking connectivity from $onprem1_vnet_name-gw gateway vm to the rest of network topology...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "ping -c 3 $hub1_vm_ip"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "ping -c 3 $spoke1_vm_ip"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "ping -c 3 $spoke2_vm_ip"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "ping -c 3 $onprem2_vm_ip"

echo -e "\e[1;36mChecking BGP routing on $onprem2_vnet_name-gw gateway vm...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo ipsec status"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo vtysh -c 'show bgp summary'"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo vtysh -c 'show ip bgp'"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo vtysh -c 'show ip route'"

echo -e "\e[1;36mChecking connectivity from $onprem2_vnet_name-gw gateway vm to the rest of network topology...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "ping -c 3 $hub1_vm_ip"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "ping -c 3 $spoke1_vm_ip"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "ping -c 3 $spoke2_vm_ip"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "ping -c 3 $onprem1_vm_ip"

echo -e "\e[1;36mLearned routes on $hub1_vnet_name-gw VNet gateway...\e[0m"
az network vnet-gateway list-learned-routes -g $rg -n $hub1_vnet_name-gw -o table
echo -e "\e[1;36mAdvertised routes on $hub1_vnet_name-gw VNet gateway to $onprem1_vnet_name-gw gateway...\e[0m"
az network vnet-gateway list-advertised-routes -g $rg -n $hub1_vnet_name-gw --peer $onprem1_gw_private_ip -o table
echo -e "\e[1;36mAdvertised routes on $hub1_vnet_name-gw VNet gateway to $onprem2_vnet_name-gw gateway...\e[0m"
az network vnet-gateway list-advertised-routes -g $rg -n $hub1_vnet_name-gw --peer $onprem2_gw_private_ip -o table

echo -e "\e[1;36mEffective route table on $hub1_vnet_name VM...\e[0m"
az network nic show-effective-route-table -g $rg -n $hub1_vnet_name -o table
echo -e "\e[1;36mEffective route table on $spoke1_vnet_name VM...\e[0m"
az network nic show-effective-route-table -g $rg -n $spoke1_vnet_name -o table
echo -e "\e[1;36mEffective route table on $spoke2_vnet_name VM...\e[0m"
az network nic show-effective-route-table -g $rg -n $spoke2_vnet_name -o table

echo -e "\e[1;35m$hub1_vnet_name-fw VM is now up. You can access it by going to https://$hub1_fw_public_ip/ \n usename: root \n passwd: opnsense\nIt's highly recommended to change the password\e[0m"
echo -e "\e[1;35mYou can also ssh root@$hub1_fw_public_ip\nPassword: opnsense\e[0m"
echo -e "\e[1;35mTo test connectivity, connect to onprem1 Gateway VM $onprem1_gw_pubip via ssh and from there, check connectivity to and from hub1 vm $hub1_vm_ip, spoke1 vm $spoke1_vm_ip and spoke2 vm $spoke2_vm_ip....\e[0m"
