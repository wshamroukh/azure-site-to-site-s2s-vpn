rg=s2s-static-nat
location1=centralindia
location2=centralindia

hub1_vnet_name=hub1
hub1_vnet_address=10.1.0.0/16
hub1_nat_address=10.10.0.0/16
hub1_gw_subnet_address=10.1.0.0/24
hub1_vm_subnet_name=vm
hub1_vm_subnet_address=10.1.1.0/24

onprem1_vnet_name=onprem1
onprem1_vnet_address=10.1.0.0/16
onprem1_nat_address=172.21.0.0/16
onprem1_gw_subnet_name=gw
onprem1_gw_subnet_address=10.1.0.0/24
onprem1_vm_subnet_name=vm
onprem1_vm_subnet_address=10.1.1.0/24

onprem2_vnet_name=onprem2
onprem2_vnet_address=10.1.0.0/16
onprem2_nat_address=172.22.0.0/16
onprem2_gw_subnet_name=gw
onprem2_gw_subnet_address=10.1.0.0/24
onprem2_vm_subnet_name=vm
onprem2_vm_subnet_address=10.1.1.0/24

admin_username=$(whoami)
psk=secret12345
vm_size=Standard_B2ats_v2


cloudinit_file=cloudinit.txt
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
     echo -e "\e[1;35mWaiting for resource $resource_name to finish provisioning...\e[0m"
     start_time=`date +%s`
     state=$(az resource show --id $resource_id --query properties.provisioningState -o tsv | tr -d '\r')
     until [[ "$state" == "Succeeded" ]] || [[ "$state" == "Failed" ]] || [[ -z "$state" ]]
     do
        sleep $wait_interval
        state=$(az resource show --id $resource_id --query properties.provisioningState -o tsv | tr -d '\r')
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

function replace_1st_2octets(){
    ip=$1
    subnet=$2
    modsub=$(echo $subnet | cut -d"/" -f 1)
    presub=$(echo $modsub | cut -d"." -f1-2)
    tailip=$(echo $ip | cut -d"." -f3-4)
    echo $presub.$tailip

}

# Resource Groups
echo -e "\e[1;36mCreating $rg Resource Group...\e[0m"
az group create -n $rg -l $location1 -o none

# hub1 vnet
echo -e "\e[1;36mCreating $hub1_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $hub1_vnet_name -l $location1 --address-prefixes $hub1_vnet_address --subnet-name $hub1_vm_subnet_name --subnet-prefixes $hub1_vm_subnet_address -o none
az network vnet subnet create -g $rg -n GatewaySubnet --address-prefixes $hub1_gw_subnet_address --vnet-name $hub1_vnet_name -o none

# hub1 vm nsg
echo -e "\e[1;36mCreating $hub1_vnet_name NSG...\e[0m"
az network nsg create -g $rg -n $hub1_vnet_name -l $location1 -o none
az network nsg rule create -g $rg -n AllowSSH --nsg-name $hub1_vnet_name --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network vnet subnet update -g $rg -n $hub1_vm_subnet_name --vnet-name $hub1_vnet_name --nsg $hub1_vnet_name -o none

# hub1 VPN GW
echo -e "\e[1;36mDeploying $hub1_vnet_name-gw VPN Gateway...\e[0m"
az network public-ip create -g $rg -n $hub1_vnet_name-gw0 -l $location1 --allocation-method Static -o none
az network public-ip create -g $rg -n $hub1_vnet_name-gw1 -l $location1 --allocation-method Static -o none
az network vnet-gateway create -g $rg -n $hub1_vnet_name-gw --public-ip-addresses $hub1_vnet_name-gw0 $hub1_vnet_name-gw1 --vnet $hub1_vnet_name --sku VpnGw2 --gateway-type Vpn --vpn-type RouteBased --no-wait

# onprem1 vnet
echo -e "\e[1;36mCreating $onprem1_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $onprem1_vnet_name -l $location1 --address-prefixes $onprem1_vnet_address --subnet-name $onprem1_vm_subnet_name --subnet-prefixes $onprem1_vm_subnet_address -o none
az network vnet subnet create -g $rg -n $onprem1_gw_subnet_name --address-prefixes $onprem1_gw_subnet_address --vnet-name $onprem1_vnet_name -o none

# onprem2 vnet
echo -e "\e[1;36mCreating $onprem2_vnet_name VNet...\e[0m"
az network vnet create -g $rg -n $onprem2_vnet_name -l $location2 --address-prefixes $onprem2_vnet_address --subnet-name $onprem2_vm_subnet_name --subnet-prefixes $onprem2_vm_subnet_address -o none
az network vnet subnet create -g $rg -n $onprem2_gw_subnet_name --address-prefixes $onprem2_gw_subnet_address --vnet-name $onprem2_vnet_name -o none

# onprem1 gw
echo -e "\e[1;36mDeploying $onprem1_vnet_name-gw VM...\e[0m"
az network public-ip create -g $rg -n $onprem1_vnet_name-gw -l $location1 --allocation-method Static --sku Basic -o none
az network nic create -g $rg -n $onprem1_vnet_name-gw -l $location1 --vnet-name $onprem1_vnet_name --subnet $onprem1_gw_subnet_name --ip-forwarding true --public-ip-address $onprem1_vnet_name-gw -o none
az vm create -g $rg -n $onprem1_vnet_name-gw -l $location1 --image Ubuntu2404 --nics $onprem1_vnet_name-gw --os-disk-name $onprem1_vnet_name-gw --size $vm_size --admin-username $admin_username --generate-ssh-keys --custom-data $cloudinit_file --no-wait
# onprem1 gw details
onprem1_gw_pubip=$(az network public-ip show -g $rg -n $onprem1_vnet_name-gw --query ipAddress -o tsv | tr -d '\r') && echo $onprem1_vnet_name-gw public ip: $onprem1_gw_pubip
onprem1_gw_private_ip=$(az network nic show -g $rg -n $onprem1_vnet_name-gw --query ipConfigurations[].privateIPAddress -o tsv | tr -d '\r')  && echo $onprem1_vnet_name-gw private ip: $onprem1_gw_private_ip

# local network gateway for onprem1
echo -e "\e[1;36mDeploying $onprem1_vnet_name-gw local network gateway resource...\e[0m"
az network local-gateway create -g $rg -n $onprem1_vnet_name-gw -l $location1 --gateway-ip-address $onprem1_gw_pubip  --local-address-prefixes $onprem1_vnet_address --no-wait

# onprem2 gw
echo -e "\e[1;36mDeploying $onprem2_vnet_name-gw VM...\e[0m"
az network public-ip create -g $rg -n $onprem2_vnet_name-gw -l $location2 --allocation-method Static --sku Basic -o none
az network nic create -g $rg -n $onprem2_vnet_name-gw -l $location2 --vnet-name $onprem2_vnet_name --subnet $onprem2_gw_subnet_name --ip-forwarding true --public-ip-address $onprem2_vnet_name-gw -o none
az vm create -g $rg -n $onprem2_vnet_name-gw -l $location2 --image Ubuntu2404 --nics $onprem2_vnet_name-gw --os-disk-name $onprem2_vnet_name-gw --size $vm_size --admin-username $admin_username --generate-ssh-keys --custom-data $cloudinit_file --no-wait
# onprem2 gw details
onprem2_gw_pubip=$(az network public-ip show -g $rg -n $onprem2_vnet_name-gw --query ipAddress -o tsv | tr -d '\r') && echo $onprem2_vnet_name-gw public ip: $onprem2_gw_pubip
onprem2_gw_private_ip=$(az network nic show -g $rg -n $onprem2_vnet_name-gw --query ipConfigurations[].privateIPAddress -o tsv | tr -d '\r')  && echo $onprem2_vnet_name-gw private ip: $onprem2_gw_private_ip

# local network gateway for onprem2
echo -e "\e[1;36mDeploying $onprem2_vnet_name-gw local network gateway resource...\e[0m"
az network local-gateway create -g $rg -n $onprem2_vnet_name-gw -l $location1 --gateway-ip-address $onprem2_gw_pubip  --local-address-prefixes $onprem2_vnet_address --no-wait

# onprem1 vm
echo -e "\e[1;36mDeploying $onprem1_vnet_name VM...\e[0m"
az network nic create -g $rg -n $onprem1_vnet_name -l $location1 --vnet-name $onprem1_vnet_name --subnet $onprem1_vm_subnet_name -o none
az vm create -g $rg -n $onprem1_vnet_name -l $location1 --image Ubuntu2404 --nics $onprem1_vnet_name --os-disk-name $onprem1_vnet_name --size $vm_size --admin-username $admin_username --generate-ssh-keys --no-wait
onprem1_vm_ip=$(az network nic show -g $rg -n $onprem1_vnet_name --query ipConfigurations[0].privateIPAddress -o tsv | tr -d '\r') && echo $onprem1_vnet_name private ip: $onprem1_vm_ip
onprem1_vm_nat_ip=$(replace_1st_2octets $onprem1_vm_ip $onprem1_nat_address) && echo $onprem2_vnet_name vm nat ip: $onprem1_vm_nat_ip

# onprem2 vm
echo -e "\e[1;36mDeploying $onprem2_vnet_name VM...\e[0m"
az network nic create -g $rg -n $onprem2_vnet_name -l $location2 --vnet-name $onprem2_vnet_name --subnet $onprem2_vm_subnet_name -o none
az vm create -g $rg -n $onprem2_vnet_name -l $location2 --image Ubuntu2404 --nics $onprem2_vnet_name --os-disk-name $onprem2_vnet_name --size $vm_size --admin-username $admin_username --generate-ssh-keys --no-wait
onprem2_vm_ip=$(az network nic show -g $rg -n $onprem2_vnet_name --query ipConfigurations[0].privateIPAddress -o tsv | tr -d '\r') && echo $onprem2_vnet_name private ip: $onprem2_vm_ip
onprem2_vm_nat_ip=$(replace_1st_2octets $onprem2_vm_ip $onprem2_nat_address) && echo $onprem2_vnet_name vm nat ip: $onprem2_vm_nat_ip

# hub1 vm
echo -e "\e[1;36mDeploying $hub1_vnet_name VM...\e[0m"
az network nic create -g $rg -n $hub1_vnet_name -l $location1 --vnet-name $hub1_vnet_name --subnet $hub1_vm_subnet_name -o none
az vm create -g $rg -n $hub1_vnet_name -l $location1 --image Ubuntu2404 --nics $hub1_vnet_name --os-disk-name $hub1_vnet_name --size $vm_size --admin-username $admin_username --generate-ssh-keys --no-wait
hub1_vm_ip=$(az network nic show -g $rg -n $hub1_vnet_name --query ipConfigurations[0].privateIPAddress -o tsv | tr -d '\r') && echo $hub1_vnet_name private ip: $hub1_vm_ip
hub1_vm_nat_ip=$(replace_1st_2octets $hub1_vm_ip $hub1_nat_address) && echo $hub1_vnet_name vm nat ip: $hub1_vm_nat_ip

# onprem1 route table
echo -e "\e[1;36mDeploying $onprem1_vnet_name route table and attaching it to $onprem1_vm_subnet_name subnet...\e[0m"
az network route-table create -g $rg -n $onprem1_vnet_name -l $location1 -o none
az network route-table route create -g $rg -n to-$hub1_vnet_name-nat --address-prefix $hub1_nat_address --next-hop-type VirtualAppliance --route-table-name $onprem1_vnet_name --next-hop-ip-address $onprem1_gw_private_ip -o none
az network route-table route create -g $rg -n to-$onprem2_vnet_name-nat --address-prefix $onprem2_nat_address --next-hop-type VirtualAppliance --route-table-name $onprem1_vnet_name --next-hop-ip-address $onprem1_gw_private_ip -o none
az network vnet subnet update -g $rg -n $onprem1_vm_subnet_name --vnet-name $onprem1_vnet_name --route-table $onprem1_vnet_name -o none

# onprem2 route table
echo -e "\e[1;36mDeploying $onprem2_vnet_name route table and attaching it to $onprem2_vm_subnet_name subnet...\e[0m"
az network route-table create -g $rg -n $onprem2_vnet_name -l $location2 -o none
az network route-table route create -g $rg -n to-$hub1_vnet_name-nat --address-prefix $hub1_nat_address --next-hop-type VirtualAppliance --route-table-name $onprem2_vnet_name --next-hop-ip-address $onprem2_gw_private_ip -o none
az network route-table route create -g $rg -n to-$onprem1_vnet_name-nat --address-prefix $onprem1_nat_address --next-hop-type VirtualAppliance --route-table-name $onprem2_vnet_name --next-hop-ip-address $onprem2_gw_private_ip -o none
az network vnet subnet update -g $rg -n $onprem2_vm_subnet_name --vnet-name $onprem2_vnet_name --route-table $onprem2_vnet_name -o none

# onprem1 vm nsg
echo -e "\e[1;36mCreating $onprem1_vnet_name NSG...\e[0m"
az network nsg create -g $rg -n $onprem1_vnet_name -l $location1 -o none
az network nsg rule create -g $rg -n AllowSSH --nsg-name $onprem1_vnet_name --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowICMP --nsg-name $onprem1_vnet_name --priority 1010 --access Allow --description AllowICMP --protocol Icmp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges '*' --source-address-prefixes '*' --source-port-ranges '*' -o none
az network vnet subnet update -g $rg -n $onprem1_vm_subnet_name --vnet-name $onprem1_vnet_name --nsg $onprem1_vnet_name -o none

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
echo -e "\e[1;36mCreating $onprem2_vnet_name NSG...\e[0m"
az network nsg create -g $rg -n $onprem2_vnet_name -l $location2 -o none
az network nsg rule create -g $rg -n AllowSSH --nsg-name $onprem2_vnet_name --priority 1000 --access Allow --description AllowSSH --protocol Tcp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges 22 --source-address-prefixes '*' --source-port-ranges '*' -o none
az network nsg rule create -g $rg -n AllowICMP --nsg-name $onprem2_vnet_name --priority 1010 --access Allow --description AllowICMP --protocol Icmp --direction Inbound --destination-address-prefixes '*' --destination-port-ranges '*' --source-address-prefixes '*' --source-port-ranges '*' -o none
az network vnet subnet update -g $rg -n $onprem2_vm_subnet_name --vnet-name $onprem2_vnet_name --nsg $onprem2_vnet_name -o none

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

# waiting on hub1 vpn gw to finish deployment
hub1_gw_id=$(az network vnet-gateway show -g $rg -n $hub1_vnet_name-gw --query id -o tsv | tr -d '\r')
wait_until_finished $hub1_gw_id

# Getting hub1 VPN GW details
echo -e "\e[1;36mGetting $hub1_vnet_name-gw VPN Gateway details...\e[0m"
hub1_gw_pubip0=$(az network vnet-gateway show -n $hub1_vnet_name-gw -g $rg --query 'bgpSettings.bgpPeeringAddresses[0].tunnelIpAddresses[0]' -o tsv | tr -d '\r') && echo $hub1_vnet_name-gw public ip: $hub1_gw_pubip0
hub1_gw_pubip1=$(az network vnet-gateway show -n $hub1_vnet_name-gw -g $rg --query 'bgpSettings.bgpPeeringAddresses[1].tunnelIpAddresses[0]' -o tsv | tr -d '\r') && echo $hub1_vnet_name-gw public ip: $hub1_gw_pubip1

# Egress NAT Rule from Azure to Branches
echo -e "\e[1;36mCreating Egress NAT rule on $hub1_vnet_name-gw VPN Gateway for $hub1_vnet_name VNet ($hub1_vnet_address-->$hub1_nat_address)...\e[0m"
az network vnet-gateway nat-rule add -g $rg -n $hub1_vnet_name-nat-rule --type Static --mode EgressSnat --internal-mappings $hub1_vnet_address --external-mappings $hub1_nat_address --gateway-name $hub1_vnet_name-gw -o none

# Ingress NAT Rule from onprem1 to Azure
echo -e "\e[1;36mCreating Ingress NAT rule on $hub1_vnet_name-gw VPN Gateway for $onprem1_vnet_name VNet ($onprem1_vnet_address-->$onprem1_nat_address)...\e[0m"
az network vnet-gateway nat-rule add -g $rg -n $onprem1_vnet_name-nat-rule --type Static --mode IngressSnat --internal-mappings $onprem1_vnet_address --external-mappings $onprem1_nat_address --gateway-name $hub1_vnet_name-gw -o none

# Ingress NAT Rule from onprem2 to Azure
echo -e "\e[1;36mCreating Ingress NAT rule on $hub1_vnet_name-gw VPN Gateway for $onprem2_vnet_name VNet ($onprem2_vnet_address-->$onprem2_nat_address)...\e[0m"
az network vnet-gateway nat-rule add -g $rg -n $onprem2_vnet_name-nat-rule --type Static --mode IngressSnat --internal-mappings $onprem2_vnet_address --external-mappings $onprem2_nat_address --gateway-name $hub1_vnet_name-gw -o none

# Get NAT rules details
echo -e "\e[1;36mGetting NAT rules details on $hub1_vnet_name-gw VPN Gateway...\e[0m"
hub1_nat_rule=$(az network vnet-gateway nat-rule list -g $rg --gateway-name $hub1_vnet_name-gw --query "[?contains(name, '"$hub1_vnet_name-nat-rule"')].[id]" -o tsv | tr -d '\r')
onprem1_nat_rule=$(az network vnet-gateway nat-rule list -g $rg --gateway-name $hub1_vnet_name-gw --query "[?contains(name, '"$onprem1_vnet_name-nat-rule"')].[id]" -o tsv | tr -d '\r')
onprem2_nat_rule=$(az network vnet-gateway nat-rule list -g $rg --gateway-name $hub1_vnet_name-gw --query "[?contains(name, '"$onprem2_vnet_name-nat-rule"')].[id]" -o tsv | tr -d '\r')

# creating VPN connection between hub1 vpn gw and onprem1 gw
echo -e "\e[1;36mCreating S2S VPN Connection between $hub1_vnet_name Azure VPN Gateway and $onprem1_vnet_name Gateway...\e[0m"
az network vpn-connection create -g $rg -n $hub1_vnet_name-gw-to-$onprem1_vnet_name-gw-s2s-connection --vnet-gateway1 $hub1_vnet_name-gw --local-gateway2 $onprem1_vnet_name-gw --shared-key $psk --ingress-nat-rule $onprem1_nat_rule --egress-nat-rule $hub1_nat_rule -o none

# creating VPN connection between hub1 vpn gw and onprem2 gw
echo -e "\e[1;36mCreating S2S VPN Connection between $hub1_vnet_name Azure VPN Gateway and $onprem2_vnet_name Gateway...\e[0m"
az network vpn-connection create -g $rg -n $hub1_vnet_name-gw-to-$onprem2_vnet_name-gw-s2s-connection --vnet-gateway1 $hub1_vnet_name-gw --local-gateway2 $onprem2_vnet_name-gw --shared-key $psk --ingress-nat-rule $onprem2_nat_rule --egress-nat-rule $hub1_nat_rule -o none


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

ipsec_vti_file=~/ipsec-vti.sh
tee $ipsec_vti_file > /dev/null <<'EOT'
#!/bin/bash
#
# /etc/strongswan.d/ipsec-vti.sh
#
set -o nounset
set -o errexit
echo "`date` ${PLUTO_VERB} $VTI_INTERFACE" >> /tmp/vtitrace.log
VTI_IF="vti${PLUTO_UNIQUEID}"

case "${PLUTO_VERB}" in
    up-client)
        ip tunnel add "${VTI_IF}" local "${PLUTO_ME}" remote "${PLUTO_PEER}" mode vti \
            okey "${PLUTO_MARK_OUT%%/*}" ikey "${PLUTO_MARK_IN%%/*}"
        ip link set "${VTI_IF}" up
        ip route add $hub1_nat_address dev "${VTI_IF}"
        ip route add $onprem2_nat_address dev "${VTI_IF}"
        sysctl -w "net.ipv4.conf.${VTI_IF}.disable_policy=1"
        ;;
    down-client)
        ip tunnel del "${VTI_IF}"
        ;;
esac
EOT

sed -i "s,\\\$hub1_nat_address,${hub1_nat_address}," $ipsec_vti_file
sed -i "s,\\\$onprem2_nat_address,${onprem2_nat_address}," $ipsec_vti_file


##### copy files to onprem gw
echo -e "\e[1;36mCopying and applying S2S VPN Config files to $onprem1_vnet_name-gw Gateway VM...\e[0m"
scp -o StrictHostKeyChecking=no $psk_file $ipsec_file $ipsec_vti_file $onprem1_gw_pubip:/home/$admin_username
scp -o StrictHostKeyChecking=no ~/.ssh/* $onprem1_gw_pubip:/home/$admin_username/.ssh/
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo mv /home/$admin_username/ipsec.* /etc/"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo mv /home/$admin_username/ipsec-vti.sh /etc/strongswan.d/"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo chmod +x /etc/strongswan.d/ipsec-vti.sh"
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

ipsec_vti_file=~/ipsec-vti.sh
tee $ipsec_vti_file > /dev/null <<'EOT'
#!/bin/bash
#
# /etc/strongswan.d/ipsec-vti.sh
#
set -o nounset
set -o errexit
echo "`date` ${PLUTO_VERB} $VTI_INTERFACE" >> /tmp/vtitrace.log
VTI_IF="vti${PLUTO_UNIQUEID}"

case "${PLUTO_VERB}" in
    up-client)
        ip tunnel add "${VTI_IF}" local "${PLUTO_ME}" remote "${PLUTO_PEER}" mode vti \
            okey "${PLUTO_MARK_OUT%%/*}" ikey "${PLUTO_MARK_IN%%/*}"
        ip link set "${VTI_IF}" up
        ip route add $hub1_nat_address dev "${VTI_IF}"
        ip route add $onprem1_nat_address dev "${VTI_IF}"
        sysctl -w "net.ipv4.conf.${VTI_IF}.disable_policy=1"
        ;;
    down-client)
        ip tunnel del "${VTI_IF}"
        ;;
esac
EOT

sed -i "s,\\\$hub1_nat_address,${hub1_nat_address}," $ipsec_vti_file
sed -i "s,\\\$onprem1_nat_address,${onprem1_nat_address}," $ipsec_vti_file


##### copy files to onprem gw
echo -e "\e[1;36mCopying and applying S2S VPN Config files to $onprem2_vnet_name-gw Gateway VM...\e[0m"
scp -o StrictHostKeyChecking=no $psk_file $ipsec_file $ipsec_vti_file $onprem2_gw_pubip:/home/$admin_username
scp -o StrictHostKeyChecking=no ~/.ssh/* $onprem2_gw_pubip:/home/$admin_username/.ssh/
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo mv /home/$admin_username/ipsec.* /etc/"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo mv /home/$admin_username/ipsec-vti.sh /etc/strongswan.d/"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo chmod +x /etc/strongswan.d/ipsec-vti.sh"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo ipsec restart"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo ipsec status"

# clean up config files
rm $psk_file $ipsec_file $ipsec_vti_file

#############
# Diagnosis #
#############
echo -e "\e[1;36mChecking IPSec VPN tunnel status on $onprem1_vnet_name-gw...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "sudo ipsec status"
echo -e "\e[1;36mChecking IPSec VPN tunnel status on $onprem2_vnet_name-gw...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "sudo ipsec status"

echo -e "\e[1;36mChecking the static route on $onprem1_vnet_name-gw to the NAT'ed IP addresses of both $hub1_vnet_name and $onprem2_vnet_name VNets...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "ip route"

echo -e "\e[1;36mChecking the static route on $onprem2_vnet_name-gw to the NAT'ed IP addresses of both $hub1_vnet_name and $onprem1_vnet_name VNets...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "ip route"

echo -e "\e[1;36mChecking the connectivity from $onprem1_vnet_name-gw to $hub1_vnet_name VM using the NAT'ed IP address ($hub1_vm_nat_ip)...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "ping $hub1_vm_nat_ip -c 3"
echo -e "\e[1;36mChecking the connectivity from $onprem1_vnet_name-gw to $onprem2_vnet_name VM using the NAT'ed IP address ($onprem2_vm_nat_ip)...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem1_gw_pubip "ping $onprem2_vm_nat_ip -c 3"

echo -e "\e[1;36mChecking the connectivity from $onprem2_vnet_name-gw to $hub1_vnet_name VM using the NAT'ed IP address ($hub1_vm_nat_ip)...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "ping $hub1_vm_nat_ip -c 3"
echo -e "\e[1;36mChecking the connectivity from $onprem2_vnet_name-gw to $onprem2_vnet_name VM using the NAT'ed IP address ($onprem2_vm_nat_ip)...\e[0m"
ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no $onprem2_gw_pubip "ping $onprem1_vm_nat_ip -c 3"

#cleanup
# az group delete -g $rg -y --no-wait