#!/bin/bash
# =============================================================
# OwnCloud Setup Scripts
# Run setup_mysql.sh on DbServer, setup_owncloud.sh on AppServer
# =============================================================

# ── setup_mysql.sh — Run on DbServer ─────────────────────────
# SSH path: local → AppServer → DbServer
#
# scp -i ~/.ssh/owncloud_key ~/.ssh/owncloud_key azureuser@<APP_IP>:~/.ssh/owncloud_key
# ssh -i ~/.ssh/owncloud_key azureuser@<APP_IP>
# chmod 600 ~/.ssh/owncloud_key && ssh -i ~/.ssh/owncloud_key azureuser@10.0.2.4

sudo apt update && sudo apt upgrade -y
sudo apt install -y mysql-server

# Configure MySQL to accept remote connections
sudo sed -i 's/bind-address.*/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf
sudo systemctl restart mysql
sudo systemctl enable mysql

# Create OwnCloud database and user
sudo mysql -u root <<EOF
CREATE DATABASE owncloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER 'ownclouduser'@'%' IDENTIFIED BY 'StrongPass123!';
GRANT ALL PRIVILEGES ON owncloud.* TO 'ownclouduser'@'%';
FLUSH PRIVILEGES;
EOF

echo "MySQL setup complete."
echo "Test with: mysql -u ownclouduser -p'StrongPass123!' -e 'SHOW DATABASES;'"


# ── setup_owncloud.sh — Run on AppServer ─────────────────────

sudo apt update && sudo apt upgrade -y
sudo apt install -y software-properties-common
sudo add-apt-repository ppa:ondrej/php -y
sudo apt update

sudo apt install -y apache2 php7.4 libapache2-mod-php7.4 \
  php7.4-mysql php7.4-xml php7.4-curl php7.4-gd \
  php7.4-mbstring php7.4-intl php7.4-zip php7.4-bz2 php7.4-imagick

# Switch Apache to PHP 7.4
sudo a2dismod php8.1 2>/dev/null || true
sudo a2dismod php8.5 2>/dev/null || true
sudo a2enmod php7.4
sudo a2enmod rewrite headers env dir mime
sudo systemctl restart apache2

# Download and install OwnCloud
wget https://download.owncloud.com/server/stable/owncloud-complete-latest.zip -P /tmp
sudo unzip -o /tmp/owncloud-complete-latest.zip -d /var/www/
sudo chown -R www-data:www-data /var/www/owncloud
sudo chmod -R 755 /var/www/owncloud

# Configure Apache virtual host
APP_IP=$(curl -s ifconfig.me)

sudo tee /etc/apache2/sites-available/owncloud.conf > /dev/null <<EOF
<VirtualHost *:80>
    DocumentRoot /var/www/owncloud
    ServerName $APP_IP

    <Directory /var/www/owncloud>
        Options +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/owncloud_error.log
    CustomLog \${APACHE_LOG_DIR}/owncloud_access.log combined
</VirtualHost>
EOF

sudo a2ensite owncloud.conf
sudo a2dissite 000-default.conf
sudo systemctl reload apache2

echo "OwnCloud setup complete."
echo "Open http://$APP_IP in your browser to complete setup."
