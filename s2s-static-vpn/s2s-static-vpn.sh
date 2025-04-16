rg=s2s
location1=centralindia
location2=centralindia

hub1_vnet_name=hub1
hub1_vnet_address=10.1.0.0/16
hub1_gw_subnet_address=10.1.0.0/24
hub1_vm_subnet_name=vm
hub1_vm_subnet_address=10.1.1.0/24

spoke1_vnet_name=spoke1
spoke1_vnet_address=10.11.0.0/16
spoke1_vm_subnet_name=vm
spoke1_vm_subnet_address=10.11.1.0/24

onprem1_vnet_name=onprem1
onprem1_vnet_address=172.21.0.0/16
onprem1_gw_subnet_name=gw
onprem1_gw_subnet_address=172.21.0.0/24
onprem1_vm_subnet_name=vm
onprem1_vm_subnet_address=172.21.1.0/24

onprem2_vnet_name=onprem2
onprem2_vnet_address=172.22.0.0/16
onprem2_gw_subnet_name=gw
onprem2_gw_subnet_address=172.22.0.0/24
onprem2_vm_subnet_name=vm
onprem2_vm_subnet_address=172.22.1.0/24

admin_username=$(whoami)
myip=$(curl -s4 https://ifconfig.co/)

psk=secret12345
vm_size=Standard_B2ats_v2


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
EOF

function wait_until_finished {
     wait_interval=15
     resource_id=$1
     resource_name=$(echo $resource_id | cut -d/ -f 9)
     echo -e "\e[1;35mWaiting for resource $resource_name to finish provisioning...\e[0m"
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
        echo -e "\e[1;32mResource $resource_name provisioning state is $state, wait time $minutes minutes and $seconds seconds\e[0m"
     fi
}

# Resource Groups
echo -e "\e[1;36mCreating $rg Resource Group...\e[0m"
az group create -n $rg -l $location1 -o none

# hub1 vnet
echo -e "\e[1;36mCreating $hub1_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $hub1_vnet_name -l $location1 --address-prefixes $hub1_vnet_address --subnet-name $hub1_vm_subnet_name --subnet-prefixes $hub1_vm_subnet_address -o none
az network vnet subnet create -g $rg -n GatewaySubnet --address-prefixes $hub1_gw_subnet_address --vnet-name $hub1_vnet_name -o none

# hub1 vm nsg
echo -e "\e[1;36mCreating $hub1_vnet_name-vm NSG...\e[0m"
az network nsg create -g $rg -n $hub1_vnet_name-vm -l $location1 -o none
az network nsg rule create -g $rg -n AllowSSH --nsg-name $hub1_vnet_name-vm --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network vnet subnet update -g $rg -n $hub1_vm_subnet_name --vnet-name $hub1_vnet_name --nsg $hub1_vnet_name-vm -o none

# hub1 VPN GW
echo -e "\e[1;36mDeploying $hub1_vnet_name-gw VPN Gateway...\e[0m"
az network public-ip create -g $rg -n $hub1_vnet_name-gw-pubip -l $location1 --allocation-method Static -o none
az network vnet-gateway create -g $rg -n $hub1_vnet_name-gw --public-ip-addresses $hub1_vnet_name-gw-pubip --vnet $hub1_vnet_name --sku VpnGw1 --gateway-type Vpn --vpn-type RouteBased --no-wait

# onprem1 vnet
echo -e "\e[1;36mCreating $onprem1_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $onprem1_vnet_name -l $location1 --address-prefixes $onprem1_vnet_address --subnet-name $onprem1_vm_subnet_name --subnet-prefixes $onprem1_vm_subnet_address -o none
az network vnet subnet create -g $rg -n $onprem1_gw_subnet_name --address-prefixes $onprem1_gw_subnet_address --vnet-name $onprem1_vnet_name -o none

# onprem2 vnet
echo -e "\e[1;36mCreating $onprem2_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $onprem2_vnet_name -l $location2 --address-prefixes $onprem2_vnet_address --subnet-name $onprem2_vm_subnet_name --subnet-prefixes $onprem2_vm_subnet_address -o none
az network vnet subnet create -g $rg -n $onprem2_gw_subnet_name --address-prefixes $onprem2_gw_subnet_address --vnet-name $onprem2_vnet_name -o none

# spoke1 vnet
echo -e "\e[1;36mCreating $spoke1_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $spoke1_vnet_name -l $location1 --address-prefixes $spoke1_vnet_address --subnet-name $spoke1_vm_subnet_name --subnet-prefixes $spoke1_vm_subnet_address -o none

# onprem1 gw vm
echo -e "\e[1;36mDeploying $onprem1_vnet_name-gw VM...\e[0m"
az network public-ip create -g $rg -n $onprem1_vnet_name-gw -l $location1 --allocation-method Static --sku Basic -o none
az network nic create -g $rg -n $onprem1_vnet_name-gw -l $location1 --vnet-name $onprem1_vnet_name --subnet $onprem1_gw_subnet_name --ip-forwarding true --public-ip-address $onprem1_vnet_name-gw -o none
az vm create -g $rg -n $onprem1_vnet_name-gw -l $location1 --image Ubuntu2404 --nics $onprem1_vnet_name-gw --os-disk-name $onprem1_vnet_name-gw --size $vm_size --admin-username $admin_username --generate-ssh-keys --custom-data $cloudinit_file --no-wait
# onprem1 gw details
onprem1_gw_pubip=$(az network public-ip show -g $rg -n $onprem1_vnet_name-gw --query ipAddress -o tsv) && echo $onprem1_vnet_name-gw public ip: $onprem1_gw_pubip
onprem1_gw_private_ip=$(az network nic show -g $rg -n $onprem1_vnet_name-gw --query ipConfigurations[].privateIPAddress -o tsv)  && echo $onprem1_vnet_name-gw private ip: $onprem1_gw_private_ip

# onprem1 local network gateway
echo -e "\e[1;36mDeploying $onprem1_vnet_name-gw local gateway resource...\e[0m"
az network local-gateway create -g $rg -n $onprem1_vnet_name-gw -l $location1 --gateway-ip-address $onprem1_gw_pubip  --local-address-prefixes $onprem1_vnet_address  -o none

# onprem1 vm
echo -e "\e[1;36mDeploying $onprem1_vnet_name VM...\e[0m"
az network nic create -g $rg -n $onprem1_vnet_name -l $location1 --vnet-name $onprem1_vnet_name --subnet $onprem1_vm_subnet_name -o none
az vm create -g $rg -n $onprem1_vnet_name -l $location1 --image Ubuntu2404 --nics $onprem1_vnet_name --os-disk-name $onprem1_vnet_name --size $vm_size --admin-username $admin_username --generate-ssh-keys --no-wait
onprem1_vm_ip=$(az network nic show -g $rg -n $onprem1_vnet_name --query ipConfigurations[].privateIPAddress -o tsv) && echo $onprem1_vnet_name vm private ip: $onprem1_vm_ip

# onprem2 gw vm
echo -e "\e[1;36mDeploying $onprem2_vnet_name-gw VM...\e[0m"
az network public-ip create -g $rg -n $onprem2_vnet_name-gw -l $location2 --allocation-method Static --sku Basic -o none
az network nic create -g $rg -n $onprem2_vnet_name-gw -l $location2 --vnet-name $onprem2_vnet_name --subnet $onprem2_gw_subnet_name --ip-forwarding true --public-ip-address $onprem2_vnet_name-gw -o none
az vm create -g $rg -n $onprem2_vnet_name-gw -l $location2 --image Ubuntu2404 --nics $onprem2_vnet_name-gw --os-disk-name $onprem2_vnet_name-gw --size $vm_size --admin-username $admin_username --generate-ssh-keys --custom-data $cloudinit_file --no-wait
# onprem2 gw details
onprem2_gw_pubip=$(az network public-ip show -g $rg -n $onprem2_vnet_name-gw --query ipAddress -o tsv) && echo $onprem2_vnet_name-gw public ip: $onprem2_gw_pubip
onprem2_gw_private_ip=$(az network nic show -g $rg -n $onprem2_vnet_name-gw --query ipConfigurations[].privateIPAddress -o tsv)  && echo $onprem2_vnet_name-gw private ip: $onprem2_gw_private_ip

# onprem2 local network gateway
echo -e "\e[1;36mDeploying $onprem2_vnet_name-gw local gateway resource...\e[0m"
az network local-gateway create -g $rg -n $onprem2_vnet_name-gw -l $location2 --gateway-ip-address $onprem2_gw_pubip  --local-address-prefixes $onprem2_vnet_address  -o none

# onprem2 vm
echo -e "\e[1;36mDeploying $onprem2_vnet_name VM...\e[0m"
az network nic create -g $rg -n $onprem2_vnet_name -l $location2 --vnet-name $onprem2_vnet_name --subnet $onprem2_vm_subnet_name -o none
az vm create -g $rg -n $onprem2_vnet_name -l $location2 --image Ubuntu2404 --nics $onprem2_vnet_name --os-disk-name $onprem2_vnet_name --size $vm_size --admin-username $admin_username --generate-ssh-keys --no-wait
onprem2_vm_ip=$(az network nic show -g $rg -n $onprem2_vnet_name --query ipConfigurations[].privateIPAddress -o tsv) && echo $onprem2_vnet_name vm private ip: $onprem2_vm_ip

# hub1 vm
echo -e "\e[1;36mDeploying $hub1_vnet_name VM...\e[0m"
az network nic create -g $rg -n $hub1_vnet_name -l $location1 --vnet-name $hub1_vnet_name --subnet $hub1_vm_subnet_name -o none
az vm create -g $rg -n $hub1_vnet_name -l $location1 --image Ubuntu2404 --nics $hub1_vnet_name --os-disk-name $hub1_vnet_name --size $vm_size --admin-username $admin_username --generate-ssh-keys --no-wait
hub1_vm_ip=$(az network nic show -g $rg -n $hub1_vnet_name --query ipConfigurations[0].privateIPAddress -o tsv)

# spoke1 vm
echo -e "\e[1;36mDeploying $spoke1_vnet_name VM...\e[0m"
az network nic create -g $rg -n $spoke1_vnet_name -l $location1 --vnet-name $spoke1_vnet_name --subnet $spoke1_vm_subnet_name -o none
az vm create -g $rg -n $spoke1_vnet_name -l $location1 --image Ubuntu2404 --nics $spoke1_vnet_name --os-disk-name $spoke1_vnet_name --size $vm_size --admin-username $admin_username --generate-ssh-keys --no-wait
spoke1_vm_ip=$(az network nic show -g $rg -n $spoke1_vnet_name --query ipConfigurations[0].privateIPAddress -o tsv)

# onprem1 route table
echo -e "\e[1;36mDeploying $onprem1_vnet_name route table and attaching it to $onprem1_vm_subnet_name subnet...\e[0m"
az network route-table create -g $rg -n $onprem1_vnet_name -l $location1 -o none
az network route-table route create -g $rg -n to-$hub1_vnet_name --address-prefix $hub1_vnet_address --next-hop-type VirtualAppliance --route-table-name $onprem1_vnet_name --next-hop-ip-address $onprem1_gw_private_ip -o none
az network route-table route create -g $rg -n to-$spoke1_vnet_name --address-prefix $spoke1_vnet_address --next-hop-type VirtualAppliance --route-table-name $onprem1_vnet_name --next-hop-ip-address $onprem1_gw_private_ip -o none
az network route-table route create -g $rg -n to-$onprem2_vnet_name --address-prefix $onprem2_vnet_address --next-hop-type VirtualAppliance --route-table-name $onprem1_vnet_name --next-hop-ip-address $onprem1_gw_private_ip -o none
az network vnet subnet update -g $rg -n $onprem1_vm_subnet_name --vnet-name $onprem1_vnet_name --route-table $onprem1_vnet_name -o none

# onprem2 route table
echo -e "\e[1;36mDeploying $onprem2_vnet_name route table and attaching it to $onprem2_vm_subnet_name subnet...\e[0m"
az network route-table create -g $rg -n $onprem2_vnet_name -l $location2 -o none
az network route-table route create -g $rg -n to-$hub1_vnet_name --address-prefix $hub1_vnet_address --next-hop-type VirtualAppliance --route-table-name $onprem2_vnet_name --next-hop-ip-address $onprem2_gw_private_ip -o none
az network route-table route create -g $rg -n to-$spoke1_vnet_name --address-prefix $spoke1_vnet_address --next-hop-type VirtualAppliance --route-table-name $onprem2_vnet_name --next-hop-ip-address $onprem2_gw_private_ip -o none
az network route-table route create -g $rg -n to-$onprem1_vnet_name --address-prefix $onprem1_vnet_address --next-hop-type VirtualAppliance --route-table-name $onprem2_vnet_name --next-hop-ip-address $onprem2_gw_private_ip -o none
az network vnet subnet update -g $rg -n $onprem2_vm_subnet_name --vnet-name $onprem2_vnet_name --route-table $onprem2_vnet_name -o none

# onprem1 vm nsg
echo -e "\e[1;36mCreating $onprem1_vnet_name-vm NSG...\e[0m"
az network nsg create -g $rg -n $onprem1_vnet_name-vm -l $location1 -o none
az network nsg rule create -g $rg -n AllowSSH --nsg-name $onprem1_vnet_name-vm --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowICMP --nsg-name $onprem1_vnet_name-vm --priority 1010 --access Allow --description AllowICMP --protocol Icmp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges '*' --source-address-prefixes '*' --source-port-ranges '*' -o none
az network vnet subnet update -g $rg -n $onprem1_vm_subnet_name --vnet-name $onprem1_vnet_name --nsg $onprem1_vnet_name-vm -o none

# onprem1 gw nsg
echo -e "\e[1;36mCreating $onprem1_vnet_name-gw NSG...\e[0m"
az network nsg create -g $rg -n $onprem1_vnet_name-gw -l $location1 -o none
az network nsg rule create -g $rg -n AllowSSHin --nsg-name $onprem1_vnet_name-gw --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowIKE --nsg-name $onprem1_vnet_name-gw --priority 1010 --access Allow --description AllowIKE --protocol Udp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 4500 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowIPSec --nsg-name $onprem1_vnet_name-gw --priority 1020 --access Allow --description AllowIPSec --protocol Udp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 500 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowICMPin --nsg-name $onprem1_vnet_name-gw --priority 1030 --access Allow --description AllowICMP --protocol Icmp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges '*' --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowSSHout --nsg-name $onprem1_vnet_name-gw --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Outbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowICMPout --nsg-name $onprem1_vnet_name-gw --priority 1010 --access Allow --description AllowICMP --protocol Icmp --direction Outbound --destination-address-prefixes '*' --destination-port-ranges '*' --source-address-prefixes '*' --source-port-ranges '*' -o none
az network vnet subnet update -g $rg -n $onprem1_gw_subnet_name --vnet-name $onprem1_vnet_name --nsg $onprem1_vnet_name-gw -o none

# onprem2 vm nsg
echo -e "\e[1;36mCreating $onprem2_vnet_name-vm NSG...\e[0m"
az network nsg create -g $rg -n $onprem2_vnet_name-vm -l $location2 -o none
az network nsg rule create -g $rg -n AllowSSH --nsg-name $onprem2_vnet_name-vm --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowICMP --nsg-name $onprem2_vnet_name-vm --priority 1010 --access Allow --description AllowICMP --protocol Icmp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges '*' --source-address-prefixes '*' --source-port-ranges '*' -o none
az network vnet subnet update -g $rg -n $onprem2_vm_subnet_name --vnet-name $onprem2_vnet_name --nsg $onprem2_vnet_name-vm -o none

# onprem2 gw nsg
echo -e "\e[1;36mCreating $onprem2_vnet_name-gw NSG...\e[0m"
az network nsg create -g $rg -n $onprem2_vnet_name-gw -l $location2 -o none
az network nsg rule create -g $rg -n AllowSSHin --nsg-name $onprem2_vnet_name-gw --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowIKE --nsg-name $onprem2_vnet_name-gw --priority 1010 --access Allow --description AllowIKE --protocol Udp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 4500 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowIPSec --nsg-name $onprem2_vnet_name-gw --priority 1020 --access Allow --description AllowIPSec --protocol Udp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 500 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowICMPin --nsg-name $onprem2_vnet_name-gw --priority 1030 --access Allow --description AllowICMP --protocol Icmp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges '*' --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowSSHout --nsg-name $onprem2_vnet_name-gw --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Outbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowICMPout --nsg-name $onprem2_vnet_name-gw --priority 1010 --access Allow --description AllowICMP --protocol Icmp --direction Outbound --destination-address-prefixes '*' --destination-port-ranges '*' --source-address-prefixes '*' --source-port-ranges '*' -o none
az network vnet subnet update -g $rg -n $onprem2_gw_subnet_name --vnet-name $onprem2_vnet_name --nsg $onprem2_vnet_name-gw -o none

# spoke1 vm nsg
echo -e "\e[1;36mCreating $spoke1_vnet_name-vm NSG...\e[0m"
az network nsg create -g $rg -n $spoke1_vnet_name-vm -l $location1 -o none
az network nsg rule create -g $rg -n AllowSSH --nsg-name $spoke1_vnet_name-vm --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network vnet subnet update -g $rg -n $spoke1_vm_subnet_name --vnet-name $spoke1_vnet_name --nsg $spoke1_vnet_name-vm -o none

# waiting on hub1 vpn gw to finish deployment
hub1_gw_id=$(az network vnet-gateway show -g $rg -n $hub1_vnet_name-gw --query id -o tsv)
wait_until_finished $hub1_gw_id

# Getting hub1 VPN GW details
echo -e "\e[1;36mGetting $hub1_vnet_name-gw VPN Gateway details...\e[0m"
hub1_gw_pubip=$(az network vnet-gateway show -n $hub1_vnet_name-gw -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]' -o tsv) && echo $hub1_vnet_name-gw: $hub1_gw_pubip

# VNet Peering between hub1 and spoke1
echo -e "\e[1;36mCreating VNet peerring between $hub1_vnet_name and $spoke1_vnet_name...\e[0m"
az network vnet peering create -g $rg -n $hub1_vnet_name-to-$spoke1_vnet_name-peering --remote-vnet $spoke1_vnet_name --vnet-name $hub1_vnet_name --allow-forwarded-traffic --allow-gateway-transit --allow-vnet-access -o none
az network vnet peering create -g $rg -n $spoke1_vnet_name-to-$hub1_vnet_name-peering --remote-vnet $hub1_vnet_name --vnet-name $spoke1_vnet_name --use-remote-gateways --allow-vnet-access -o none

# creating VPN connection between hub1 vpn gw and onprem1 gw
echo -e "\e[1;36mCreating $hub1_vnet_name-gw-to-$onprem1_vnet_name-gw-s2s-connection...\e[0m"
az network vpn-connection create -g $rg -n $hub1_vnet_name-gw-to-$onprem1_vnet_name-gw-s2s-connection --vnet-gateway1 $hub1_vnet_name-gw --local-gateway2 $onprem1_vnet_name-gw --shared-key $psk -o none

# creating VPN connection between hub1 vpn gw and onprem2 gw
echo -e "\e[1;36mCreating $hub1_vnet_name-gw-to-$onprem2_vnet_name-gw-s2s-connection...\e[0m"
az network vpn-connection create -g $rg -n $hub1_vnet_name-gw-to-$onprem2_vnet_name-gw-s2s-connection --vnet-gateway1 $hub1_vnet_name-gw --local-gateway2 $onprem2_vnet_name-gw --shared-key $psk -o none

#######################
# onprem1 VPN Config  #
#######################
echo -e "\e[1;36mCreating S2S/BGP VPN Config files for $onprem1_vnet_name Gateway VM...\e[0m"
# ipsec.secrets
psk_file=~/ipsec.secrets
cat <<EOF > $psk_file
$onprem1_gw_pubip $hub1_gw_pubip : PSK $psk
EOF

ipsec_file=~/ipsec.conf
cat <<EOF > $ipsec_file
conn $hub1_vnet_name-gw
         dpdaction=restart
         ike=aes256-sha1-modp1024
         esp=aes256-sha1
         keyexchange=ikev2
         ikelifetime=28800s
         keylife=3600s
         authby=secret
         # onprem1 private ip address
         left=$onprem1_gw_private_ip
         # onprem1 Public ip address
         leftid=$onprem1_gw_pubip
         # onprem1 Address Space2
         leftsubnet=$onprem1_vnet_address
         # Azure VPN Gateway Public IP
         right=$hub1_gw_pubip
         # Azure VPN Gateway Public IP
         rightid=$hub1_gw_pubip
         # Azure Vnet Address Spaces and onther on-premises network address space (comma separated, if more that one i.e hub and spoke topology)
         rightsubnet=$hub1_vnet_address,$spoke1_vnet_address,$onprem2_vnet_address
         auto=start
EOF

##### copy files to onprem gw
echo -e "\e[1;36mCopying and applying S2S VPN Config files to $onprem1_vnet_name-gw Gateway VM...\e[0m"
scp -o StrictHostKeyChecking=no $psk_file $ipsec_file $onprem1_gw_pubip:/home/$admin_username
scp -o StrictHostKeyChecking=no ~/.ssh/* $onprem1_gw_pubip:/home/$admin_username/.ssh/
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo mv /home/$admin_username/ipsec.* /etc/"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo ipsec restart"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo ipsec status"

# clean up config files
rm $psk_file $ipsec_file $cloudinit_file


#######################
# onprem2 VPN Config  #
#######################
echo -e "\e[1;36mCreating S2S/BGP VPN Config files for $onprem2_vnet_name Gateway VM...\e[0m"
# ipsec.secrets
psk_file=~/ipsec.secrets
cat <<EOF > $psk_file
$onprem2_gw_pubip $hub1_gw_pubip : PSK $psk
EOF

ipsec_file=~/ipsec.conf
cat <<EOF > $ipsec_file
conn $hub1_vnet_name-gw
         dpdaction=restart
         ike=aes256-sha1-modp1024
         esp=aes256-sha1
         keyexchange=ikev2
         ikelifetime=28800s
         keylife=3600s
         authby=secret
         # onprem2 private ip address
         left=$onprem2_gw_private_ip
         # onprem2 Public ip address
         leftid=$onprem2_gw_pubip
         # onprem2 Address Space2
         leftsubnet=$onprem2_vnet_address
         # Azure VPN Gateway Public IP
         right=$hub1_gw_pubip
         # Azure VPN Gateway Public IP
         rightid=$hub1_gw_pubip
         # Azure Vnet Address Spaces and onther on-premises network address space (comma separated, if more that one i.e hub and spoke topology)
         rightsubnet=$hub1_vnet_address,$spoke1_vnet_address,$onprem1_vnet_address
         auto=start
EOF

##### copy files to onprem gw
echo -e "\e[1;36mCopying and applying S2S VPN Config files to $onprem2_vnet_name-gw Gateway VM...\e[0m"
scp -o StrictHostKeyChecking=no $psk_file $ipsec_file $onprem2_gw_pubip:/home/$admin_username
scp -o StrictHostKeyChecking=no ~/.ssh/* $onprem2_gw_pubip:/home/$admin_username/.ssh/
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo mv /home/$admin_username/ipsec.* /etc/"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo ipsec restart"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo ipsec status"

# clean up config files
rm $psk_file $ipsec_file

#############
# Diagnosis #
#############
echo -e "\e[1;36mChecking S2S VPN Tunnel on $onprem1_vnet_name-gw...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo ipsec status"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo ipsec statusall"

echo -e "\e[1;36mChecking connectivity from $onprem1_vnet_name-gw Gateway VM to $hub1_vnet_name VM...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "ping $hub1_vm_ip -c 3"

echo -e "\e[1;36mChecking connectivity from $onprem1_vnet_name-gw Gateway VM to $spoke1_vnet_name VM...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "ping $spoke1_vm_ip -c 3"

echo -e "\e[1;36mChecking connectivity from $onprem1_vnet_name-gw Gateway VM to $onprem2_vnet_name VM...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "ping $onprem2_vm_ip -c 3"

echo -e "\e[1;36mChecking S2S VPN Tunnel on $onprem2_vnet_name-gw...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo ipsec status"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo ipsec statusall"

echo -e "\e[1;36mChecking connectivity from $onprem2_vnet_name-gw Gateway VM to $hub1_vnet_name VM...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "ping $hub1_vm_ip -c 3"

echo -e "\e[1;36mChecking connectivity from $onprem2_vnet_name-gw Gateway VM to $spoke1_vnet_name VM...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "ping $spoke1_vm_ip -c 3"

echo -e "\e[1;36mChecking connectivity from $onprem2_vnet_name-gw Gateway VM to $onprem1_vnet_name VM...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "ping $onprem1_vm_ip -c 3"

#cleanup
# az group delete -g $rg -y --no-wait