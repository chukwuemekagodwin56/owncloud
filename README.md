# Secure File Sharing on Azure — OwnCloud Deployment

![Azure](https://img.shields.io/badge/Azure-Cloud-blue) ![OwnCloud](https://img.shields.io/badge/OwnCloud-File--Sharing-lightblue) ![MySQL](https://img.shields.io/badge/MySQL-Database-orange) ![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%2F%2020.04-purple)

## Overview

This project deploys a **self-hosted, secure file sharing platform** on Microsoft Azure using OwnCloud, replacing unauthorised Dropbox usage in a mid-size financial services company. All data remains within the company's Azure tenant, the database is isolated from the public internet, and the application is accessible to employees via a web browser.

---

## Architecture

```
Web Browser ──HTTP:80──► [ Public Subnet 10.0.1.0/24 ]      [ Private Subnet 10.0.2.0/24 ]
                          ┌─────────────────────────┐        ┌──────────────────────────┐
                          │   Application Server     │        │     Database Server       │
                          │   Ubuntu 22.04           │◄──────►│     Ubuntu 20.04          │
                          │   OwnCloud + Apache      │  3306  │     MySQL                 │
                          │   Public IP + AppNSG     │        │     No Public IP + DbNSG  │
                          └─────────────────────────┘        └──────────────────────────┘
                                        Virtual Network — P1VNET (10.0.0.0/16)
                                        NAT Gateway (Private Subnet → Internet)
```

### Why This Architecture?
- **Public subnet** hosts the OwnCloud web app — employees access it via browser over HTTP
- **Private subnet** isolates the MySQL database — no direct internet access, reducing attack surface
- **NAT Gateway** lets the database server pull updates from the internet without being exposed
- **Separate NSGs** enforce least-privilege: AppNSG allows ports 22 and 80; DbNSG allows ports 22 and 3306
- **SSH jump host pattern** — the database VM is accessed by SSHing into the app server (bastion), then hopping to the private VM

---

## Prerequisites

- Azure CLI installed and logged in (`az login`)
- PowerShell (Windows)
- An active Azure subscription

---

## Deployment Steps

### 1. Set Variables

```powershell
$RG = "rg-owncloud56"; $LOC = "westus2"; $VNET = "P1VNET"; $ADMIN = "azureuser"
```

---

### 2. Create Network Infrastructure

```powershell
# Create Resource Group
az group create --name $RG --location $LOC

# Create VNet with Public Subnet
az network vnet create `
  --resource-group $RG --name $VNET --location $LOC `
  --address-prefix 10.0.0.0/16 `
  --subnet-name PublicSubnet --subnet-prefix 10.0.1.0/24

# Create Private Subnet
az network vnet subnet create `
  --resource-group $RG --vnet-name $VNET `
  --name PrivateSubnet --address-prefix 10.0.2.0/24

# Create NAT Gateway
az network public-ip create `
  --resource-group $RG --name NatGwIP --sku Standard --allocation-method Static

az network nat gateway create `
  --resource-group $RG --name NatGateway `
  --public-ip-addresses NatGwIP --idle-timeout 10

az network vnet subnet update `
  --resource-group $RG --vnet-name $VNET `
  --name PrivateSubnet --nat-gateway NatGateway
```

---

### 3. Configure Network Security Groups

```powershell
# AppNSG — allow SSH (22) and HTTP (80)
az network nsg create --resource-group $RG --name AppNSG

az network nsg rule create `
  --resource-group $RG --nsg-name AppNSG `
  --name Allow-SSH --priority 100 `
  --protocol Tcp --destination-port-ranges 22 --access Allow --direction Inbound

az network nsg rule create `
  --resource-group $RG --nsg-name AppNSG `
  --name Allow-HTTP --priority 110 `
  --protocol Tcp --destination-port-ranges 80 --access Allow --direction Inbound

# DbNSG — allow SSH (22) and MySQL (3306)
az network nsg create --resource-group $RG --name DbNSG

az network nsg rule create `
  --resource-group $RG --nsg-name DbNSG `
  --name Allow-SSH --priority 100 `
  --protocol Tcp --destination-port-ranges 22 --access Allow --direction Inbound

az network nsg rule create `
  --resource-group $RG --nsg-name DbNSG `
  --name Allow-MySQL --priority 110 `
  --protocol Tcp --destination-port-ranges 3306 --access Allow --direction Inbound
```

---

### 4. Generate SSH Key

```powershell
New-Item -ItemType Directory -Path "$HOME\.ssh" -Force
ssh-keygen -t rsa -b 2048 -f "$HOME\.ssh\owncloud_key" -N ""
```

---

### 5. Deploy Virtual Machines

```powershell
# Application Server — Public Subnet, Ubuntu 22.04, with Public IP
az vm create `
  --resource-group $RG --name AppServer `
  --image Ubuntu2204 --size Standard_B2s --location $LOC `
  --vnet-name $VNET --subnet PublicSubnet `
  --public-ip-address AppPublicIP `
  --admin-username $ADMIN `
  --ssh-key-values "$HOME\.ssh\owncloud_key.pub"

# Database Server — Private Subnet, Ubuntu 20.04, NO Public IP
az vm create `
  --resource-group $RG --name DbServer `
  --image Ubuntu2004 --size Standard_B2s --location $LOC `
  --vnet-name $VNET --subnet PrivateSubnet `
  --public-ip-address '""' `
  --admin-username $ADMIN `
  --ssh-key-values "$HOME\.ssh\owncloud_key.pub"

# Attach NSGs directly to NICs
az network nic update `
  --resource-group $RG --name AppServerVMNic --network-security-group AppNSG

az network nic update `
  --resource-group $RG --name DbServerVMNic --network-security-group DbNSG
```

---

### 6. Install MySQL on the Database Server

Copy SSH key to AppServer and hop to DbServer:

```powershell
# From local machine — copy private key to AppServer
scp -i "$HOME\.ssh\owncloud_key" "$HOME\.ssh\owncloud_key" azureuser@<APP_PUBLIC_IP>:~/.ssh/owncloud_key

# SSH into AppServer
ssh -i "$HOME\.ssh\owncloud_key" azureuser@<APP_PUBLIC_IP>
```

```bash
# From AppServer — hop to DbServer
chmod 600 ~/.ssh/owncloud_key
ssh -i ~/.ssh/owncloud_key azureuser@10.0.2.4
```

On the **DbServer**:

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y mysql-server
sudo mysql_secure_installation
```

Create the OwnCloud database:

```bash
sudo mysql -u root -p
```

```sql
CREATE DATABASE owncloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER 'ownclouduser'@'%' IDENTIFIED BY 'StrongPass123!';
GRANT ALL PRIVILEGES ON owncloud.* TO 'ownclouduser'@'%';
FLUSH PRIVILEGES;
EXIT;
```

Configure MySQL to accept remote connections:

```bash
sudo nano /etc/mysql/mysql.conf.d/mysqld.cnf
# Change: bind-address = 127.0.0.1
# To:     bind-address = 0.0.0.0

sudo systemctl restart mysql
sudo systemctl enable mysql
```

---

### 7. Install OwnCloud on the Application Server

SSH into AppServer and run:

```bash
# Install PHP 7.4 (OwnCloud is not compatible with PHP 8.x)
sudo apt install -y software-properties-common
sudo add-apt-repository ppa:ondrej/php -y
sudo apt update

sudo apt install -y apache2 php7.4 libapache2-mod-php7.4 \
  php7.4-mysql php7.4-xml php7.4-curl php7.4-gd \
  php7.4-mbstring php7.4-intl php7.4-zip php7.4-bz2 php7.4-imagick

# Switch Apache to PHP 7.4
sudo a2dismod php8.1
sudo a2enmod php7.4
sudo a2enmod rewrite headers env dir mime
sudo systemctl restart apache2

# Download and install OwnCloud
wget https://download.owncloud.com/server/stable/owncloud-complete-latest.zip -P /tmp
sudo unzip /tmp/owncloud-complete-latest.zip -d /var/www/
sudo chown -R www-data:www-data /var/www/owncloud
sudo chmod -R 755 /var/www/owncloud
```

Configure Apache virtual host:

```bash
sudo nano /etc/apache2/sites-available/owncloud.conf
```

```apache
<VirtualHost *:80>
    DocumentRoot /var/www/owncloud
    ServerName <APP_PUBLIC_IP>

    <Directory /var/www/owncloud>
        Options +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/owncloud_error.log
    CustomLog ${APACHE_LOG_DIR}/owncloud_access.log combined
</VirtualHost>
```

```bash
sudo a2ensite owncloud.conf
sudo a2dissite 000-default.conf
sudo systemctl reload apache2
```

---

### 8. Complete Setup via Browser

Navigate to `http://<APP_PUBLIC_IP>` and fill in the OwnCloud setup wizard:

| Field | Value |
|---|---|
| Admin username | `admin` |
| Admin password | Your choice |
| Data folder | `/var/www/owncloud/data` |
| Database user | `ownclouduser` |
| Database password | `StrongPass123!` |
| Database name | `owncloud` |
| Database host | `10.0.2.4:3306` |

Click **Finish Setup** ✅

---

## Troubleshooting

| Issue | Fix |
|---|---|
| `LocationRequired` on VNet create | Add `--location $LOC` flag |
| VM SKU not available | Use `Standard_B2s` instead of `Standard_B1s` |
| SSH `Permission denied (publickey)` | Run `az vm user update` to push correct public key, use `scp` to copy private key to AppServer |
| Port 80 unreachable from browser | Attach NSG directly to NIC: `az network nic update --network-security-group AppNSG` |
| OwnCloud PHP 8.x incompatibility | Install PHP 7.4 via `ppa:ondrej/php` and switch Apache module |
| MySQL remote connection refused | Set `bind-address = 0.0.0.0` in `mysqld.cnf` and restart MySQL |
| `---` comment causes PowerShell error | PowerShell comments use `#`, not `---` |
| Multiple variable assignments on one line | Use `;` as separator or put each on its own line |

---

## Resource Summary

| Resource | Name | Value |
|---|---|---|
| Resource Group | `rg-owncloud56` | `westus2` |
| Virtual Network | `P1VNET` | `10.0.0.0/16` |
| Public Subnet | `PublicSubnet` | `10.0.1.0/24` |
| Private Subnet | `PrivateSubnet` | `10.0.2.0/24` |
| App Server | `AppServer` | Ubuntu 22.04, Standard_B2s |
| DB Server | `DbServer` | Ubuntu 20.04, Standard_B2s |
| App NSG | `AppNSG` | Ports 22, 80 |
| DB NSG | `DbNSG` | Ports 22, 3306 |
| NAT Gateway | `NatGateway` | Private subnet outbound |

---

## Security Notes

- The database server has **no public IP** — it is only reachable from within the VNet
- SSH access to the database server requires **jumping through the app server** (bastion pattern)
- NSGs enforce **least-privilege** — only required ports are open
- All data stays within the **Azure tenant** — no third-party cloud storage

---

## License

MIT
