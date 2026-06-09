# =============================================================
# Secure File Sharing on Azure — OwnCloud Deployment Script
# =============================================================
# Usage: Run each section in order from PowerShell
# Prerequisites: Azure CLI installed, az login completed
# =============================================================

# ── VARIABLES ─────────────────────────────────────────────────
$RG    = "rg-owncloud56"
$LOC   = "westus2"
$VNET  = "P1VNET"
$ADMIN = "azureuser"

# ── STEP 1: RESOURCE GROUP ────────────────────────────────────
az group create --name $RG --location $LOC

# ── STEP 2: VIRTUAL NETWORK ───────────────────────────────────
az network vnet create `
  --resource-group $RG --name $VNET --location $LOC `
  --address-prefix 10.0.0.0/16 `
  --subnet-name PublicSubnet --subnet-prefix 10.0.1.0/24

az network vnet subnet create `
  --resource-group $RG --vnet-name $VNET `
  --name PrivateSubnet --address-prefix 10.0.2.0/24

# ── STEP 3: NAT GATEWAY ───────────────────────────────────────
az network public-ip create `
  --resource-group $RG --name NatGwIP `
  --sku Standard --allocation-method Static

az network nat gateway create `
  --resource-group $RG --name NatGateway `
  --public-ip-addresses NatGwIP --idle-timeout 10

az network vnet subnet update `
  --resource-group $RG --vnet-name $VNET `
  --name PrivateSubnet --nat-gateway NatGateway

# ── STEP 4: NETWORK SECURITY GROUPS ──────────────────────────
# AppNSG
az network nsg create --resource-group $RG --name AppNSG

az network nsg rule create `
  --resource-group $RG --nsg-name AppNSG `
  --name Allow-SSH --priority 100 `
  --protocol Tcp --destination-port-ranges 22 `
  --access Allow --direction Inbound

az network nsg rule create `
  --resource-group $RG --nsg-name AppNSG `
  --name Allow-HTTP --priority 110 `
  --protocol Tcp --destination-port-ranges 80 `
  --access Allow --direction Inbound

# DbNSG
az network nsg create --resource-group $RG --name DbNSG

az network nsg rule create `
  --resource-group $RG --nsg-name DbNSG `
  --name Allow-SSH --priority 100 `
  --protocol Tcp --destination-port-ranges 22 `
  --access Allow --direction Inbound

az network nsg rule create `
  --resource-group $RG --nsg-name DbNSG `
  --name Allow-MySQL --priority 110 `
  --protocol Tcp --destination-port-ranges 3306 `
  --access Allow --direction Inbound

# ── STEP 5: SSH KEY ───────────────────────────────────────────
New-Item -ItemType Directory -Path "$HOME\.ssh" -Force
ssh-keygen -t rsa -b 2048 -f "$HOME\.ssh\owncloud_key" -N ""

# ── STEP 6: VIRTUAL MACHINES ──────────────────────────────────
# Application Server
az vm create `
  --resource-group $RG --name AppServer `
  --image Ubuntu2204 --size Standard_B2s --location $LOC `
  --vnet-name $VNET --subnet PublicSubnet `
  --public-ip-address AppPublicIP `
  --admin-username $ADMIN `
  --ssh-key-values "$HOME\.ssh\owncloud_key.pub"

# Database Server (no public IP)
az vm create `
  --resource-group $RG --name DbServer `
  --image Ubuntu2004 --size Standard_B2s --location $LOC `
  --vnet-name $VNET --subnet PrivateSubnet `
  --public-ip-address '""' `
  --admin-username $ADMIN `
  --ssh-key-values "$HOME\.ssh\owncloud_key.pub"

# ── STEP 7: ATTACH NSGs TO NICs ───────────────────────────────
az network nic update `
  --resource-group $RG --name AppServerVMNic `
  --network-security-group AppNSG

az network nic update `
  --resource-group $RG --name DbServerVMNic `
  --network-security-group DbNSG

# ── STEP 8: GET IPs ───────────────────────────────────────────
Write-Host "App Server Public IP:"
az vm show --resource-group $RG --name AppServer --show-details --query publicIps -o tsv

Write-Host "DB Server Private IP:"
az vm show --resource-group $RG --name DbServer --show-details --query privateIps -o tsv
