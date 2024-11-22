rg=s2s-nat-bgp
location1=centralindia
location2=centralindia

hub1_vnet_name=hub1
hub1_vnet_address=10.1.0.0/16
hub1_nat_address=10.10.0.0/16
hub1_gw_subnet_address=10.1.0.0/24
hub1_gw_asn=65515
hub1_vm_subnet_name=vm
hub1_vm_subnet_address=10.1.1.0/24

spoke1_vnet_name=spoke1
spoke1_vnet_address=10.11.0.0/16
spoke1_vm_subnet_name=vm
spoke1_vm_subnet_address=10.11.1.0/24

spoke2_vnet_name=spoke2
spoke2_vnet_address=10.12.0.0/16
spoke2_vm_subnet_name=vm
spoke2_vm_subnet_address=10.12.1.0/24

onprem1_vnet_name=onprem1
onprem1_vnet_address=10.1.0.0/16
onprem1_nat_address=172.21.0.0/16
onprem1_gw_subnet_name=gw
onprem1_gw_subnet_address=10.1.0.0/24
onprem1_gw_asn=65521
onprem1_gw_private_ip=10.1.0.21
onprem1_gw_vti0=10.1.0.250
onprem1_gw_vti1=10.1.0.251
onprem1_vm_subnet_name=vm
onprem1_vm_subnet_address=10.1.1.0/24

onprem2_vnet_name=onprem2
onprem2_vnet_address=10.1.0.0/16
onprem2_nat_address=172.22.0.0/16
onprem2_gw_subnet_name=gw
onprem2_gw_subnet_address=10.1.0.0/24
onprem2_gw_asn=65522
onprem2_gw_private_ip=10.1.0.22
onprem2_gw_vti0=10.1.0.250
onprem2_gw_vti1=10.1.0.251
onprem2_vm_subnet_name=vm
onprem2_vm_subnet_address=10.1.1.0/24

admin_username=$(whoami)
psk=secret12345
vm_size=Standard_B2ats_v2
vm_image=$(az vm image list -l $location1 -p Canonical -s 22_04-lts --all --query "[?offer=='0001-com-ubuntu-server-jammy'].urn" -o tsv | sort -u | tail -n 1) && echo $vm_image

cloudinit_file=~/cloudinit.txt
cat <<EOF > $cloudinit_file
#cloud-config
runcmd:
  - curl -s https://deb.frrouting.org/frr/keys.gpg | sudo tee /usr/share/keyrings/frrouting.gpg > /dev/null
  - echo deb [signed-by=/usr/share/keyrings/frrouting.gpg] https://deb.frrouting.org/frr \$(lsb_release -s -c) frr-stable | sudo tee -a /etc/apt/sources.list.d/frr.list
  - sudo apt update && sudo apt install -y frr frr-pythontools
  - sudo apt install -y strongswan inetutils-traceroute net-tools
  - sudo sed -i "/bgpd=no/ s//bgpd=yes/" /etc/frr/daemons
  - sudo service frr restart
  - touch /etc/strongswan.d/ipsec-vti.sh
  - chmod +x /etc/strongswan.d/ipsec-vti.sh
  - cp /etc/ipsec.conf /etc/ipsec.conf.bak
  - cp /etc/ipsec.secrets /etc/ipsec.secrets.bak
  - echo "net.ipv4.conf.all.forwarding=1" | sudo tee -a /etc/sysctl.conf
  - echo "net.ipv4.conf.default.forwarding=1" | sudo tee -a /etc/sysctl.conf
  - sudo sysctl -p
  - sed -i "s/# install_routes = yes/install_routes = no/" /etc/strongswan.d/charon.conf
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

function replace_1st_2octets(){
    ip=$1
    subnet=$2
    modsub=$(echo $subnet | cut -d"/" -f 1)
    presub=$(echo $modsub | cut -d"." -f1-2)
    tailip=$(echo $ip | cut -d"." -f3-4)
    echo $presub.$tailip

}

function fourth_ip(){
    subnet=10.1.0.0/24
    IP=$(echo $subnet | cut -d/ -f 1)
    IP_HEX=$(printf '%.2X%.2X%.2X%.2X\n' `echo $IP | sed -e 's/\./ /g'`)
    NEXT_IP_HEX=$(printf %.8X `echo $(( 0x$IP_HEX + 4 ))`)
    NEXT_IP=$(printf '%d.%d.%d.%d\n' `echo $NEXT_IP_HEX | sed -r 's/(..)/0x\1 /g'`)
    echo "$NEXT_IP"
}

# Resource Groups
echo -e "\e[1;36mCreating $rg Resource Group...\e[0m"
az group create -n $rg -l $location1 -o none

# hub1 vnet
echo -e "\e[1;36mCreating $hub1_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $hub1_vnet_name -l $location1 --address-prefixes $hub1_vnet_address --subnet-name $hub1_vm_subnet_name --subnet-prefixes $hub1_vm_subnet_address -o none
az network vnet subnet create -g $rg -n GatewaySubnet --address-prefixes $hub1_gw_subnet_address --vnet-name $hub1_vnet_name -o none

# hub1 vm nsg
echo -e "\e[1;36mCreating $hub1_vnet_name-vm-nsg NSG...\e[0m"
az network nsg create -g $rg -n $hub1_vnet_name-vm-nsg -l $location1 -o none
az network nsg rule create -g $rg -n AllowSSH --nsg-name $hub1_vnet_name-vm-nsg --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network vnet subnet update -g $rg -n $hub1_vm_subnet_name --vnet-name $hub1_vnet_name --nsg $hub1_vnet_name-vm-nsg -o none

# hub1 VPN GW
echo -e "\e[1;36mDeploying $hub1_vnet_name-gw VPN Gateway...\e[0m"
az network public-ip create -g $rg -n $hub1_vnet_name-gw-pubip0 -l $location1 --allocation-method Static -o none
az network public-ip create -g $rg -n $hub1_vnet_name-gw-pubip1 -l $location1 --allocation-method Static -o none
az network vnet-gateway create -g $rg -n $hub1_vnet_name-gw --public-ip-addresses $hub1_vnet_name-gw-pubip0 $hub1_vnet_name-gw-pubip1 --vnet $hub1_vnet_name --sku VpnGw2 --gateway-type Vpn --vpn-type RouteBased --asn $hub1_gw_asn --no-wait

# spoke1 vnet
echo -e "\e[1;36mCreating $spoke1_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $spoke1_vnet_name -l $location1 --address-prefixes $spoke1_vnet_address --subnet-name $spoke1_vm_subnet_name --subnet-prefixes $spoke1_vm_subnet_address -o none

# spoke2 vnet
echo -e "\e[1;36mCreating $spoke2_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $spoke2_vnet_name -l $location2 --address-prefixes $spoke2_vnet_address --subnet-name $spoke2_vm_subnet_name --subnet-prefixes $spoke2_vm_subnet_address -o none

# onprem1 vnet
echo -e "\e[1;36mCreating $onprem1_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $onprem1_vnet_name -l $location1 --address-prefixes $onprem1_vnet_address --subnet-name $onprem1_vm_subnet_name --subnet-prefixes $onprem1_vm_subnet_address -o none
az network vnet subnet create -g $rg -n $onprem1_gw_subnet_name --address-prefixes $onprem1_gw_subnet_address --vnet-name $onprem1_vnet_name -o none

# onprem2 vnet
echo -e "\e[1;36mCreating $onprem2_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $onprem2_vnet_name -l $location2 --address-prefixes $onprem2_vnet_address --subnet-name $onprem2_vm_subnet_name --subnet-prefixes $onprem2_vm_subnet_address -o none
az network vnet subnet create -g $rg -n $onprem2_gw_subnet_name --address-prefixes $onprem2_gw_subnet_address --vnet-name $onprem2_vnet_name -o none

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

# onprem1 gw
echo -e "\e[1;36mDeploying $onprem1_vnet_name-gw VM...\e[0m"
az network public-ip create -g $rg -n $onprem1_vnet_name-gw -l $location1 --allocation-method Static --sku Basic -o none
az network nic create -g $rg  -n $onprem1_vnet_name-gw -l $location1 --vnet-name $onprem1_vnet_name --subnet $onprem1_gw_subnet_name --ip-forwarding true --public-ip-address $onprem1_vnet_name-gw --private-ip-address $onprem1_gw_private_ip -o none
az vm create -g $rg -n $onprem1_vnet_name-gw -l $location1 --image $vm_image --nics $onprem1_vnet_name-gw --os-disk-name $onprem1_vnet_name-gw --size $vm_size --admin-username $admin_username --generate-ssh-keys --custom-data $cloudinit_file --no-wait
# onprem1 gw details
onprem1_gw_pubip=$(az network public-ip show -g $rg -n $onprem1_vnet_name-gw --query ipAddress -o tsv) && echo $onprem1_vnet_name-gw public ip: $onprem1_gw_pubip
onprem1_gw_private_ip=$(az network nic show -g $rg -n $onprem1_vnet_name-gw --query ipConfigurations[].privateIPAddress -o tsv)  && echo $onprem1_vnet_name-gw private ip: $onprem1_gw_private_ip
onprem1_gw_nic_default_gw=$(first_ip $onprem1_gw_subnet_address) && echo $onprem1_gw_nic_default_gw
onprem1_gw_nat_private_ip=$(replace_1st_2octets $onprem1_gw_private_ip $onprem1_nat_address) && echo $onprem1_vnet_name-gw NAT private ip: $onprem1_gw_nat_private_ip

# local network gateway for onprem1
echo -e "\e[1;36mDeploying $onprem1_vnet_name-gw local network gateway resource...\e[0m"
az network local-gateway create -g $rg -n $onprem1_vnet_name-gw -l $location1 --gateway-ip-address $onprem1_gw_pubip --asn $onprem1_gw_asn --bgp-peering-address $onprem1_gw_nat_private_ip --local-address-prefixes $onprem1_vnet_address --no-wait

# onprem2 gw
echo -e "\e[1;36mDeploying $onprem2_vnet_name-gw VM...\e[0m"
az network public-ip create -g $rg -n $onprem2_vnet_name-gw -l $location2 --allocation-method Static --sku Basic -o none
az network nic create -g $rg  -n $onprem2_vnet_name-gw -l $location2 --vnet-name $onprem2_vnet_name --subnet $onprem2_gw_subnet_name --ip-forwarding true --public-ip-address $onprem2_vnet_name-gw --private-ip-address $onprem2_gw_private_ip -o none
az vm create -g $rg -n $onprem2_vnet_name-gw -l $location2 --image $vm_image --nics $onprem2_vnet_name-gw --os-disk-name $onprem2_vnet_name-gw --size $vm_size --admin-username $admin_username --generate-ssh-keys --custom-data $cloudinit_file --no-wait
# onprem2 gw details
onprem2_gw_pubip=$(az network public-ip show -g $rg -n $onprem2_vnet_name-gw --query ipAddress -o tsv) && echo $onprem2_vnet_name-gw public ip: $onprem2_gw_pubip
onprem2_gw_private_ip=$(az network nic show -g $rg -n $onprem2_vnet_name-gw --query ipConfigurations[].privateIPAddress -o tsv)  && echo $onprem2_vnet_name-gw private ip: $onprem2_gw_private_ip
onprem2_gw_nic_default_gw=$(first_ip $onprem2_gw_subnet_address) && echo $onprem2_gw_nic_default_gw
onprem2_gw_nat_private_ip=$(replace_1st_2octets $onprem2_gw_private_ip $onprem2_nat_address) && echo $onprem2_vnet_name-gw NAT private ip: $onprem2_gw_nat_private_ip

# local network gateway for onprem2
echo -e "\e[1;36mDeploying $onprem2_vnet_name-gw local network gateway resource...\e[0m"
az network local-gateway create -g $rg -n $onprem2_vnet_name-gw -l $location1 --gateway-ip-address $onprem2_gw_pubip --asn $onprem2_gw_asn --bgp-peering-address $onprem2_gw_nat_private_ip --local-address-prefixes $onprem2_vnet_address --no-wait

# spoke1 vm
echo -e "\e[1;36mDeploying $spoke1_vnet_name VM...\e[0m"
az network nic create -g $rg -n $spoke1_vnet_name -l $location1 --vnet-name $spoke1_vnet_name --subnet $spoke1_vm_subnet_name -o none
az vm create -g $rg -n $spoke1_vnet_name -l $location1 --image $vm_image --nics $spoke1_vnet_name --os-disk-name $spoke1_vnet_name --size $vm_size --admin-username $admin_username --generate-ssh-keys --no-wait
spoke1_vm_ip=$(az network nic show -g $rg -n $spoke1_vnet_name --query ipConfigurations[0].privateIPAddress -o tsv) && echo $spoke1_vnet_name vm private ip: $spoke1_vm_ip

# spoke2 vm
echo -e "\e[1;36mDeploying $spoke2_vnet_name VM...\e[0m"
az network nic create -g $rg -n $spoke2_vnet_name -l $location2 --vnet-name $spoke2_vnet_name --subnet $spoke2_vm_subnet_name -o none
az vm create -g $rg -n $spoke2_vnet_name -l $location2 --image $vm_image --nics $spoke2_vnet_name --os-disk-name $spoke2_vnet_name --size $vm_size --admin-username $admin_username --generate-ssh-keys --no-wait
spoke2_vm_ip=$(az network nic show -g $rg -n $spoke2_vnet_name --query ipConfigurations[0].privateIPAddress -o tsv) && echo $spoke2_vnet_name vm private ip: $spoke2_vm_ip

# onprem1 vm
echo -e "\e[1;36mDeploying $onprem1_vnet_name VM...\e[0m"
az network nic create -g $rg -n $onprem1_vnet_name -l $location1 --vnet-name $onprem1_vnet_name --subnet $onprem1_vm_subnet_name -o none
az vm create -g $rg -n $onprem1_vnet_name -l $location1 --image $vm_image --nics $onprem1_vnet_name --os-disk-name $onprem1_vnet_name --size $vm_size --admin-username $admin_username --generate-ssh-keys --no-wait
onprem1_vm_ip=$(az network nic show -g $rg -n $onprem1_vnet_name --query ipConfigurations[0].privateIPAddress -o tsv) && echo $onprem1_vnet_name private ip: $onprem1_vm_ip
onprem1_vm_nat_ip=$(replace_1st_2octets $onprem1_vm_ip $onprem1_nat_address) && echo $onprem2_vnet_name vm nat ip: $onprem1_vm_nat_ip

# onprem2 vm
echo -e "\e[1;36mDeploying $onprem2_vnet_name VM...\e[0m"
az network nic create -g $rg -n $onprem2_vnet_name -l $location2 --vnet-name $onprem2_vnet_name --subnet $onprem2_vm_subnet_name -o none
az vm create -g $rg -n $onprem2_vnet_name -l $location2 --image $vm_image --nics $onprem2_vnet_name --os-disk-name $onprem2_vnet_name --size $vm_size --admin-username $admin_username --generate-ssh-keys --no-wait
onprem2_vm_ip=$(az network nic show -g $rg -n $onprem2_vnet_name --query ipConfigurations[0].privateIPAddress -o tsv) && echo $onprem2_vnet_name private ip: $onprem2_vm_ip
onprem2_vm_nat_ip=$(replace_1st_2octets $onprem2_vm_ip $onprem2_nat_address) && echo $onprem2_vnet_name vm nat ip: $onprem2_vm_nat_ip

# hub1 vm
echo -e "\e[1;36mDeploying $hub1_vnet_name VM...\e[0m"
az network nic create -g $rg -n $hub1_vnet_name -l $location1 --vnet-name $hub1_vnet_name --subnet $hub1_vm_subnet_name -o none
az vm create -g $rg -n $hub1_vnet_name -l $location1 --image $vm_image --nics $hub1_vnet_name --os-disk-name $hub1_vnet_name --size $vm_size --admin-username $admin_username --generate-ssh-keys --no-wait
hub1_vm_ip=$(az network nic show -g $rg -n $hub1_vnet_name --query ipConfigurations[0].privateIPAddress -o tsv) && echo $hub1_vnet_name private ip: $hub1_vm_ip
hub1_vm_nat_ip=$(replace_1st_2octets $hub1_vm_ip $hub1_nat_address) && echo $hub1_vnet_name vm nat ip: $hub1_vm_nat_ip

# onprem1 route table
echo -e "\e[1;36mDeploying $onprem1_vnet_name route table and attaching it to $onprem1_vm_subnet_name subnet...\e[0m"
az network route-table create -g $rg -n $onprem1_vnet_name -l $location1 -o none
az network route-table route create -g $rg -n to-$hub1_vnet_name-nat --address-prefix $hub1_nat_address --next-hop-type VirtualAppliance --route-table-name $onprem1_vnet_name --next-hop-ip-address $onprem1_gw_private_ip -o none
az network route-table route create -g $rg -n to-$onprem2_vnet_name-nat --address-prefix $onprem2_nat_address --next-hop-type VirtualAppliance --route-table-name $onprem1_vnet_name --next-hop-ip-address $onprem1_gw_private_ip -o none
az network route-table route create -g $rg -n to-$spoke1_vnet_name --address-prefix $spoke1_vnet_address --next-hop-type VirtualAppliance --route-table-name $onprem1_vnet_name --next-hop-ip-address $onprem1_gw_private_ip -o none
az network route-table route create -g $rg -n to-$spoke2_vnet_name --address-prefix $spoke2_vnet_address --next-hop-type VirtualAppliance --route-table-name $onprem1_vnet_name --next-hop-ip-address $onprem1_gw_private_ip -o none
az network vnet subnet update -g $rg -n $onprem1_vm_subnet_name --vnet-name $onprem1_vnet_name --route-table $onprem1_vnet_name -o none

# onprem2 route table
echo -e "\e[1;36mDeploying $onprem2_vnet_name route table and attaching it to $onprem2_vm_subnet_name subnet...\e[0m"
az network route-table create -g $rg -n $onprem2_vnet_name -l $location2 -o none
az network route-table route create -g $rg -n to-$hub1_vnet_name-nat --address-prefix $hub1_nat_address --next-hop-type VirtualAppliance --route-table-name $onprem2_vnet_name --next-hop-ip-address $onprem2_gw_private_ip -o none
az network route-table route create -g $rg -n to-$onprem1_vnet_name-nat --address-prefix $onprem1_nat_address --next-hop-type VirtualAppliance --route-table-name $onprem2_vnet_name --next-hop-ip-address $onprem2_gw_private_ip -o none
az network route-table route create -g $rg -n to-$spoke1_vnet_name --address-prefix $spoke1_vnet_address --next-hop-type VirtualAppliance --route-table-name $onprem2_vnet_name --next-hop-ip-address $onprem2_gw_private_ip -o none
az network route-table route create -g $rg -n to-$spoke2_vnet_name --address-prefix $spoke2_vnet_address --next-hop-type VirtualAppliance --route-table-name $onprem2_vnet_name --next-hop-ip-address $onprem2_gw_private_ip -o none
az network vnet subnet update -g $rg -n $onprem2_vm_subnet_name --vnet-name $onprem2_vnet_name --route-table $onprem2_vnet_name -o none

# waiting on hub1 vpn gw to finish deployment
hub1_gw_id=$(az network vnet-gateway show -g $rg -n $hub1_vnet_name-gw --query id -o tsv)
wait_until_finished $hub1_gw_id

# Getting hub1 VPN GW details
echo -e "\e[1;36mGetting $hub1_vnet_name-gw VPN Gateway details...\e[0m"
hub1_gw_pubip0=$(az network vnet-gateway show -n $hub1_vnet_name-gw -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]' -o tsv) && echo $hub1_vnet_name-gw public ip0: $hub1_gw_pubip0
hub1_gw_pubip1=$(az network vnet-gateway show -n $hub1_vnet_name-gw -g $rg --query 'bgpSettings.bgpPeeringAddresses[1].tunnelIpAddresses[0]' -o tsv) && echo $hub1_vnet_name-gw public ip1: $hub1_gw_pubip1
hub1_gw_bgp_ip0=$(az network vnet-gateway show -n $hub1_vnet_name-gw -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].defaultBgpIpAddresses[0]' -o tsv) && echo $hub1_vnet_name-gw: $hub1_gw_bgp_ip0
hub1_gw_bgp_ip1=$(az network vnet-gateway show -n $hub1_vnet_name-gw -g $rg --query 'bgpSettings.bgpPeeringAddresses[1].defaultBgpIpAddresses[0]' -o tsv) && echo $hub1_vnet_name-gw: $hub1_gw_bgp_ip1
hub1_gw_asn=$(az network vnet-gateway show -n $hub1_vnet_name-gw -g $rg --query bgpSettings.asn -o tsv) && echo $hub1_vnet_name-gw: $hub1_gw_asn
hub1_gw_nat_bgp_ip0=$(replace_1st_2octets $hub1_gw_bgp_ip0 $hub1_nat_address) && echo $hub1_vnet_name-gw NAT private ip: $hub1_gw_nat_bgp_ip0
hub1_gw_nat_bgp_ip1=$(replace_1st_2octets $hub1_gw_bgp_ip1 $hub1_nat_address) && echo $hub1_vnet_name-gw NAT private ip: $hub1_gw_nat_bgp_ip1

# VNet Peering between hub1 and spoke1
echo -e "\e[1;36mCreating VNet peerring between $hub1_vnet_name and $spoke1_vnet_name...\e[0m"
az network vnet peering create -g $rg -n $hub1_vnet_name-to-$spoke1_vnet_name-peering --remote-vnet $spoke1_vnet_name --vnet-name $hub1_vnet_name --allow-forwarded-traffic --allow-gateway-transit --allow-vnet-access -o none
az network vnet peering create -g $rg -n $spoke1_vnet_name-to-$hub1_vnet_name-peering --remote-vnet $hub1_vnet_name --vnet-name $spoke1_vnet_name --use-remote-gateways --allow-vnet-access -o none

# VNet Peering between hub1 and spoke2
echo -e "\e[1;36mCreating VNet peerring between $hub1_vnet_name and $spoke2_vnet_name...\e[0m"
az network vnet peering create -g $rg -n $hub1_vnet_name-to-$spoke2_vnet_name-peering --remote-vnet $spoke2_vnet_name --vnet-name $hub1_vnet_name --allow-forwarded-traffic --allow-gateway-transit --allow-vnet-access -o none
az network vnet peering create -g $rg -n $spoke2_vnet_name-to-$hub1_vnet_name-peering --remote-vnet $hub1_vnet_name --vnet-name $spoke2_vnet_name --use-remote-gateways --allow-vnet-access -o none

# spoke1 route table
echo -e "\e[1;36mDeploying $spoke1_vnet_name route table and attaching it to $spoke1_vm_subnet_name subnet...\e[0m"
az network route-table create -g $rg -n $spoke1_vnet_name -l $location1 -o none
az network route-table route create -g $rg -n to-$spoke2_vnet_name --address-prefix $spoke2_vnet_address --next-hop-type VirtualAppliance --route-table-name $spoke1_vnet_name --next-hop-ip-address $hub1_gw_bgp_ip0 -o none
az network vnet subnet update -g $rg -n $spoke1_vm_subnet_name --vnet-name $spoke1_vnet_name --route-table $spoke1_vnet_name -o none

# spoke2 route table
echo -e "\e[1;36mDeploying $spoke2_vnet_name route table and attaching it to $spoke2_vm_subnet_name subnet...\e[0m"
az network route-table create -g $rg -n $spoke2_vnet_name -l $location2 -o none
az network route-table route create -g $rg -n to-$spoke1_vnet_name --address-prefix $spoke1_vnet_address --next-hop-type VirtualAppliance --route-table-name $spoke2_vnet_name --next-hop-ip-address $hub1_gw_bgp_ip0 -o none
az network vnet subnet update -g $rg -n $spoke2_vm_subnet_name --vnet-name $spoke2_vnet_name --route-table $spoke2_vnet_name -o none

echo -e "\e[1;36mCreating NAT rules on $hub1_vnet_name-gw VPN Gateway...\e[0m"
# Egress NAT Rule from Azure to Branches
az network vnet-gateway nat-rule add -g $rg --name $hub1_vnet_name-nat-rule --type Static --mode EgressSnat --internal-mappings $hub1_vnet_address --external-mappings $hub1_nat_address --gateway-name $hub1_vnet_name-gw -o none

# Ingress NAT Rule from onprem1 to Azure
az network vnet-gateway nat-rule add -g $rg --name $onprem1_vnet_name-nat-rule --type Static --mode IngressSnat --internal-mappings $onprem1_vnet_address --external-mappings $onprem1_nat_address --gateway-name $hub1_vnet_name-gw -o none

# Ingress NAT Rule from onprem2 to Azure
az network vnet-gateway nat-rule add -g $rg --name $onprem2_vnet_name-nat-rule --type Static --mode IngressSnat --internal-mappings $onprem2_vnet_address --external-mappings $onprem2_nat_address --gateway-name $hub1_vnet_name-gw -o none

# Enable Bgp Route Translation
az network vnet-gateway update -n $hub1_vnet_name-gw -g $rg --set enableBgpRouteTranslationForNat=true -o none

# Get NAT rules details
hub1_nat_rule=$(az network vnet-gateway nat-rule list -g $rg --gateway-name $hub1_vnet_name-gw --query "[?contains(name, '"$hub1_vnet_name-nat-rule"')].[id]" -o tsv)
onprem1_nat_rule=$(az network vnet-gateway nat-rule list -g $rg --gateway-name $hub1_vnet_name-gw --query "[?contains(name, '"$onprem1_vnet_name-nat-rule"')].[id]" -o tsv)
onprem2_nat_rule=$(az network vnet-gateway nat-rule list -g $rg --gateway-name $hub1_vnet_name-gw --query "[?contains(name, '"$onprem2_vnet_name-nat-rule"')].[id]" -o tsv)

# creating VPN connection between hub1 vpn gw and onprem1 gw
echo -e "\e[1;36mCreating S2S VPN Connection between Azure VPN Gateway $hub1_vnet_name and onprem1 Gateway $onprem1_vnet_name...\e[0m"
az network vpn-connection create -g $rg -n $hub1_vnet_name-gw-to-$onprem1_vnet_name-gw-s2s-connection --vnet-gateway1 $hub1_vnet_name-gw --local-gateway2 $onprem1_vnet_name-gw --shared-key $psk --ingress-nat-rule $onprem1_nat_rule --egress-nat-rule $hub1_nat_rule --enable-bgp -o none

# creating VPN connection between hub1 vpn gw and onprem2 gw
echo -e "\e[1;36mCreating S2S VPN Connection between Azure VPN Gateway $hub1_vnet_name and onprem2 Gateway $onprem2_vnet_name...\e[0m"
az network vpn-connection create -g $rg -n $hub1_vnet_name-gw-to-$onprem2_vnet_name-gw-s2s-connection --vnet-gateway1 $hub1_vnet_name-gw --local-gateway2 $onprem2_vnet_name-gw --shared-key $psk --ingress-nat-rule $onprem2_nat_rule --egress-nat-rule $hub1_nat_rule --enable-bgp -o none

#######################
# onprem1 VPN Config  #
#######################
echo -e "\e[1;36mCreating S2S/BGP VPN Config files for $onprem1_vnet_name Gateway VM...\e[0m"
# ipsec.secrets
psk_file=~/ipsec.secrets
cat <<EOF > $psk_file
$onprem1_gw_pubip $hub1_gw_pubip0 : PSK $psk
$onprem1_gw_pubip $hub1_gw_pubip1 : PSK $psk
EOF

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
         leftsubnet=0.0.0.0/0
         rightsubnet=0.0.0.0/0
         leftupdown=/etc/strongswan.d/ipsec-vti.sh
         compress=no
         mobike=no
conn $hub1_vnet_name-gw0
         # OnPrem Gateway Private IP Address :
         left=$onprem1_gw_private_ip
         # OnPrem Gateway Public IP Address :
         leftid=$onprem1_gw_pubip
         # Azure VPN Gateway Public IP address :
         right=$hub1_gw_pubip0
         rightid=$hub1_gw_pubip0
         auto=start
         # unique number per IPSEC Tunnel eg. 100, 101 etc
         mark=101
conn $hub1_vnet_name-gw1
         # OnPrem Gateway Private IP Address :
         left=$onprem1_gw_private_ip
         # OnPrem Gateway Public IP Address :
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
echo "`date` ${PLUTO_VERB} $VTI_INTERFACE" >> /tmp/vtitrace.log
case "$PLUTO_CONNECTION" in
  $hub1_vnet_name-gw0)
    VTI_INTERFACE=vti0
    VTI_LOCALADDR=$onprem1_gw_vti0/32
    VTI_REMOTEADDR=$hub1_gw_nat_bgp_ip0/32
    ;;
  $hub1_vnet_name-gw1)
    VTI_INTERFACE=vti1
    VTI_LOCALADDR=$onprem1_gw_vti1/32
    VTI_REMOTEADDR=$hub1_gw_nat_bgp_ip1/32
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
sed -i "/\$hub1_gw_nat_bgp_ip0/ s//$hub1_gw_nat_bgp_ip0/" $ipsec_vti_file
sed -i "/\$hub1_gw_nat_bgp_ip1/ s//$hub1_gw_nat_bgp_ip1/" $ipsec_vti_file
sed -i "/\$hub1_vnet_name-gw0/ s//$hub1_vnet_name-gw0/" $ipsec_vti_file
sed -i "/\$hub1_vnet_name-gw1/ s//$hub1_vnet_name-gw1/" $ipsec_vti_file



# frr.conf
frr_conf_file=~/frr.conf
cat <<EOF > $frr_conf_file
frr version 8.2.2
frr defaults traditional
hostname $onprem1_vnet_name-gw
log syslog informational
no ipv6 forwarding
service integrated-vtysh-config
!
ip route $onprem1_vnet_address $onprem1_gw_nic_default_gw
ip route $hub1_gw_bgp_ip0/32 vti0
ip route $hub1_gw_bgp_ip1/32 vti1
!
router bgp $onprem1_gw_asn
 bgp router-id $onprem1_gw_private_ip
 no bgp ebgp-requires-policy
 neighbor $hub1_gw_nat_bgp_ip0 remote-as $hub1_gw_asn
 neighbor $hub1_gw_nat_bgp_ip0 description $hub1_vnet_name-gw-0
 neighbor $hub1_gw_nat_bgp_ip0 ebgp-multihop 2
 neighbor $hub1_gw_nat_bgp_ip1 remote-as $hub1_gw_asn
 neighbor $hub1_gw_nat_bgp_ip1 description $hub1_vnet_name-gw-1
 neighbor $hub1_gw_nat_bgp_ip1 ebgp-multihop 2
 !
 address-family ipv4 unicast
  network $onprem1_vnet_address
  neighbor $hub1_gw_nat_bgp_ip0 soft-reconfiguration inbound
  neighbor $hub1_gw_nat_bgp_ip1 soft-reconfiguration inbound
 exit-address-family
exit
!
EOF

##### copy files to onprem gw
scp -o StrictHostKeyChecking=no $psk_file $ipsec_file $ipsec_vti_file $frr_conf_file $onprem1_gw_pubip:/home/$admin_username
scp -o StrictHostKeyChecking=no ~/.ssh/* $onprem1_gw_pubip:/home/$admin_username/.ssh/
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo mv /home/$admin_username/frr.conf /etc/frr/frr.conf"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo mv /home/$admin_username/ipsec.* /etc/"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo mv /home/$admin_username/ipsec-vti.sh /etc/strongswan.d/"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "chmod +x /etc/strongswan.d/ipsec-vti.sh"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo ipsec restart"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo service frr restart"
echo -e "\e[1;36mChecking the status of S2S VPN between $onprem1_vnet_name-gw and $hub1_vnet_name-gw VPN Gateways...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo ipsec status"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo ipsec stop && sudo ipsec start && sudo ipsec status && ip a"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "ip a"


# clean up config files
rm $psk_file $ipsec_file $ipsec_vti_file $cloudinit_file


#######################
# onprem2 VPN Config  #
#######################
echo -e "\e[1;36mCreating S2S/BGP VPN Config files for $onprem2_vnet_name Gateway VM...\e[0m"
# ipsec.secrets
psk_file=~/ipsec.secrets
cat <<EOF > $psk_file
$onprem2_gw_pubip $hub1_gw_pubip0 : PSK $psk
$onprem2_gw_pubip $hub1_gw_pubip1 : PSK $psk
EOF

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
         leftsubnet=0.0.0.0/0
         rightsubnet=0.0.0.0/0
         leftupdown=/etc/strongswan.d/ipsec-vti.sh
         compress=no
         mobike=no
conn $hub1_vnet_name-gw0
         # OnPrem Gateway Private IP Address :
         left=$onprem2_gw_private_ip
         # OnPrem Gateway Public IP Address :
         leftid=$onprem2_gw_pubip
         # Azure VPN Gateway Public IP address :
         right=$hub1_gw_pubip0
         rightid=$hub1_gw_pubip0
         auto=start
         # unique number per IPSEC Tunnel eg. 100, 101 etc
         mark=101
conn $hub1_vnet_name-gw1
         # OnPrem Gateway Private IP Address :
         left=$onprem2_gw_private_ip
         # OnPrem Gateway Public IP Address :
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
echo "`date` ${PLUTO_VERB} $VTI_INTERFACE" >> /tmp/vtitrace.log
case "$PLUTO_CONNECTION" in
  $hub1_vnet_name-gw0)
    VTI_INTERFACE=vti0
    VTI_LOCALADDR=$onprem2_gw_vti0/32
    VTI_REMOTEADDR=$hub1_gw_nat_bgp_ip0/32
    ;;
  $hub1_vnet_name-gw1)
    VTI_INTERFACE=vti1
    VTI_LOCALADDR=$onprem2_gw_vti1/32
    VTI_REMOTEADDR=$hub1_gw_nat_bgp_ip1/32
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
sed -i "/\$hub1_gw_nat_bgp_ip0/ s//$hub1_gw_nat_bgp_ip0/" $ipsec_vti_file
sed -i "/\$hub1_gw_nat_bgp_ip1/ s//$hub1_gw_nat_bgp_ip1/" $ipsec_vti_file
sed -i "/\$hub1_vnet_name-gw0/ s//$hub1_vnet_name-gw0/" $ipsec_vti_file
sed -i "/\$hub1_vnet_name-gw1/ s//$hub1_vnet_name-gw1/" $ipsec_vti_file

# frr.conf
frr_conf_file=~/frr.conf
cat <<EOF > $frr_conf_file
frr version 8.2.2
frr defaults traditional
hostname $onprem2_vnet_name-gw
log syslog informational
no ipv6 forwarding
service integrated-vtysh-config
!
ip route $onprem2_vnet_address $onprem2_gw_nic_default_gw
ip route $hub1_gw_bgp_ip0/32 vti0
ip route $hub1_gw_bgp_ip1/32 vti1
!
router bgp $onprem2_gw_asn
 bgp router-id $onprem2_gw_private_ip
 no bgp ebgp-requires-policy
 neighbor $hub1_gw_nat_bgp_ip0 remote-as $hub1_gw_asn
 neighbor $hub1_gw_nat_bgp_ip0 description $hub1_vnet_name-gw-0
 neighbor $hub1_gw_nat_bgp_ip0 ebgp-multihop 2
 neighbor $hub1_gw_nat_bgp_ip1 remote-as $hub1_gw_asn
 neighbor $hub1_gw_nat_bgp_ip1 description $hub1_vnet_name-gw-1
 neighbor $hub1_gw_nat_bgp_ip1 ebgp-multihop 2
 !
 address-family ipv4 unicast
  network $onprem2_vnet_address
  neighbor $hub1_gw_nat_bgp_ip0 soft-reconfiguration inbound
  neighbor $hub1_gw_nat_bgp_ip1 soft-reconfiguration inbound
 exit-address-family
exit
!
EOF

##### copy files to onprem gw
scp -o StrictHostKeyChecking=no $psk_file $ipsec_file $ipsec_vti_file $frr_conf_file $onprem2_gw_pubip:/home/$admin_username
scp -o StrictHostKeyChecking=no ~/.ssh/* $onprem2_gw_pubip:/home/$admin_username/.ssh/
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo mv /home/$admin_username/frr.conf /etc/frr/frr.conf"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo mv /home/$admin_username/ipsec.* /etc/"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo mv /home/$admin_username/ipsec-vti.sh /etc/strongswan.d/"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "chmod +x /etc/strongswan.d/ipsec-vti.sh"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo ipsec restart"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo service frr restart"
# clean up config files
rm $psk_file $ipsec_file $ipsec_vti_file $frr_conf_file


#############
# Diagnosis #
#############
echo -e "\e[1;36mChecking the status of S2S VPN between $onprem1_vnet_name-gw and $hub1_vnet_name-gw VPN Gateways...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo ipsec status"
echo -e "\e[1;36mChecking BGP routing on $onprem1_vnet_name-gw gateway vm...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo vtysh -c 'show bgp summary'"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo vtysh -c 'show bgp all'"
echo -e "\e[1;36mChecking received routes on $onprem1_vnet_name-gw from $hub1_vnet_name-gw...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo vtysh -c 'show ip bgp neighbors $hub1_gw_bgp_ip0 received-routes'"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo vtysh -c 'show ip bgp neighbors $hub1_gw_bgp_ip1 received-routes'"
echo -e "\e[1;36mChecking advertised routes from $onprem1_vnet_name-gw to $hub1_vnet_name-gw...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo vtysh -c 'show ip bgp neighbors $hub1_gw_bgp_ip0 advertised-routes'"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo vtysh -c 'show ip bgp neighbors $hub1_gw_bgp_ip1 advertised-routes'"

echo -e "\e[1;36mChecking connectivity from $onprem1_vnet_name-gw gateway vm to the rest of network topology...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "ping $hub1_vm_nat_ip -c 3"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "ping $onprem2_vm_nat_ip -c 3"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "ping $spoke1_vm_ip -c 3"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "ping $spoke2_vm_ip -c 3"

echo -e "\e[1;36mChecking BGP routing on $onprem2_vnet_name-gw gateway vm...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo vtysh -c 'show bgp summary'"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo vtysh -c 'show bgp all'"
echo -e "\e[1;36mChecking received routes on $onprem2_vnet_name-gw from $hub1_vnet_name-gw...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo vtysh -c 'show ip bgp neighbors $hub1_gw_bgp_ip0 received-routes'"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo vtysh -c 'show ip bgp neighbors $hub1_gw_bgp_ip1 received-routes'"
echo -e "\e[1;36mChecking advertised routes from $onprem2_vnet_name-gw to $hub1_vnet_name-gw...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo vtysh -c 'show ip bgp neighbors $hub1_gw_bgp_ip0 advertised-routes'"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo vtysh -c 'show ip bgp neighbors $hub1_gw_bgp_ip1 advertised-routes'"

echo -e "\e[1;36mChecking connectivity from $onprem2_vnet_name-gw gateway vm to the rest of network topology...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "ping $hub1_vm_nat_ip -c 3"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "ping $onprem1_vm_nat_ip -c 3"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "ping $spoke1_vm_ip -c 3"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "ping $spoke2_vm_ip -c 3"

echo -e "\e[1;36mLearned routes on $hub1_vnet_name-gw VNet gateway...\e[0m"
az network vnet-gateway list-learned-routes -g $rg -n $hub1_vnet_name-gw -o table
echo -e "\e[1;36mAdvertised routes on $hub1_vnet_name-gw VNet gateway to $onprem1_vnet_name-gw gateway...\e[0m"
az network vnet-gateway list-advertised-routes -g $rg -n $hub1_vnet_name-gw --peer $onprem1_gw_nat_private_ip -o table
echo -e "\e[1;36mAdvertised routes on $hub1_vnet_name-gw VNet gateway to $onprem2_vnet_name-gw gateway...\e[0m"
az network vnet-gateway list-advertised-routes -g $rg -n $hub1_vnet_name-gw --peer $onprem2_gw_nat_private_ip -o table

echo -e "\e[1;36mEffective route table on $hub1_vnet_name VM...\e[0m"
az network nic show-effective-route-table -g $rg -n $hub1_vnet_name -o table
echo -e "\e[1;36mEffective route table on $spoke1_vnet_name VM...\e[0m"
az network nic show-effective-route-table -g $rg -n $spoke1_vnet_name -o table
echo -e "\e[1;36mEffective route table on $spoke2_vnet_name VM...\e[0m"
az network nic show-effective-route-table -g $rg -n $spoke2_vnet_name -o table

#cleanup
# az group delete -g $rg -y --no-wait