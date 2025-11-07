#!/bin/bash
# install-phpipam-docker.sh – Installation Script for phpIPAM inside a Docker container
#
# Adapted for Docker: replaces systemctl/ufw/hostnamectl/timedatectl with alternatives
# Works for Debian/Ubuntu-based container images.

set -e
export DEBIAN_FRONTEND=noninteractive

# ----------- CONFIGURABLE SETTINGS -----------
IPAM_DB_NAME="phpipam"
IPAM_DB_USER="phpipamuser"
IPAM_DB_PASS="StrongPassword123!"
MYSQL_ROOT_PASSWORD="MyRootPass123!"
WEB_DIR="/var/www/html/phpipam"
TIMEZONE="America/Los_Angeles"
HOSTNAME="phpipam-container"
LOGFILE="install-phpipam.log"
# ---------------------------------------------

exec > >(tee -a "$LOGFILE") 2>&1

echo "==> Installing required tools..."
apt update && apt install -y expect curl wget nano git unzip net-tools software-properties-common lsb-release ca-certificates apt-transport-https gnupg apache2 mariadb-server

echo "==> Checking for existing MariaDB data..."
if [ -d "/var/lib/mysql" ]; then
    echo "Warning: Existing MariaDB data found. Backing up..."
    service mariadb stop || true
    mv /var/lib/mysql "/var/lib/mysql.bak-$(date +%F_%H-%M-%S)" || true
fi

echo "==> Ensuring MariaDB data directory..."
mkdir -p /var/lib/mysql
chown mysql:mysql /var/lib/mysql
chmod 700 /var/lib/mysql

echo "==> Initializing MariaDB data directory..."
if [ -z "$(ls -A /var/lib/mysql)" ]; then
    mariadb-install-db --user=mysql --datadir=/var/lib/mysql
else
    echo "Warning: /var/lib/mysql is not empty. Fixing permissions..."
    chown -R mysql:mysql /var/lib/mysql
    chmod -R 700 /var/lib/mysql
fi

echo "==> Starting MariaDB service (Docker compatible)..."
service mariadb start

# ---- Robust verification block ----
MAX_WAIT=10
WAITED=0
while [ ! -S /run/mysqld/mysqld.sock ]; do
    sleep 1
    WAITED=$((WAITED + 1))
    if [ $WAITED -ge $MAX_WAIT ]; then
        echo "Error: MariaDB socket not found after ${MAX_WAIT}s. Check logs in /var/log/mysql/"
        tail -n 20 /var/log/mysql/error.log 2>/dev/null || true
        exit 1
    fi
done

if ! pgrep -x "mysqld" >/dev/null && ! pgrep -x "mariadbd" >/dev/null; then
    echo "Error: MariaDB process not detected. Check logs in /var/log/mysql/"
    exit 1
fi

if ! mysqladmin ping --silent >/dev/null 2>&1; then
    echo "MariaDB not responding immediately, waiting a bit more..."
    sleep 3
    if ! mysqladmin ping --silent >/dev/null 2>&1; then
        echo "Error: MariaDB failed to respond after startup. Check /var/log/mysql/error.log"
        exit 1
    fi
fi

echo "MariaDB service is up and responding."
# ---------------------------------------------

echo "==> Automating mysql_secure_installation using expect..."
expect <<EOD
set timeout 30
spawn mysql_secure_installation
expect "Enter current password for root (enter for none):"
send "\r"
expect "Switch to unix_socket authentication"
send "n\r"
expect "Change the root password?"
send "y\r"
expect "New password:"
send "$MYSQL_ROOT_PASSWORD\r"
expect "Re-enter new password:"
send "$MYSQL_ROOT_PASSWORD\r"
expect "Remove anonymous users?"
send "y\r"
expect "Disallow root login remotely?"
send "y\r"
expect "Remove test database and access to it?"
send "y\r"
expect "Reload privilege tables now?"
send "y\r"
expect eof
EOD

echo "==> Testing MariaDB root login..."
if ! mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
    echo "Error: MariaDB root login failed."
    exit 1
fi

echo "==> Creating phpIPAM database and user..."
mysql -u root -p"$MYSQL_ROOT_PASSWORD" <<EOF
CREATE DATABASE IF NOT EXISTS $IPAM_DB_NAME;
CREATE USER IF NOT EXISTS '$IPAM_DB_USER'@'localhost' IDENTIFIED BY '$IPAM_DB_PASS';
GRANT ALL PRIVILEGES ON $IPAM_DB_NAME.* TO '$IPAM_DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

echo "==> Setting hostname and timezone..."
echo "$HOSTNAME" > /etc/hostname
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime

echo "==> Skipping UFW firewall setup (not applicable inside Docker)..."

echo "==> Installing PHP 8.2 and dependencies..."
apt purge -y php* libapache2-mod-php || true
add-apt-repository ppa:ondrej/php -y
apt update
apt install -y php8.2 php8.2-mysql php8.2-gd php8.2-curl php8.2-mbstring php8.2-xml php8.2-zip php8.2-gmp php8.2-bcmath php8.2-intl php8.2-cli php-pear libapache2-mod-php8.2
update-alternatives --install /usr/bin/php php /usr/bin/php8.2 82
update-alternatives --set php /usr/bin/php8.2

echo "==> Downloading and configuring phpIPAM..."
cd /var/www/html
rm -rf phpipam
git clone https://github.com/phpipam/phpipam.git
chown -R www-data:www-data phpipam
cd phpipam
cp config.dist.php config.php

echo "==> Creating Apache virtual host..."
cat >/etc/apache2/sites-available/phpipam.conf <<EOF
<VirtualHost *:80>
    DocumentRoot /var/www/html/phpipam
    ServerName phpipam.local

    <Directory /var/www/html/phpipam>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF

a2ensite phpipam.conf
a2dissite 000-default.conf
a2enmod rewrite
service apache2 reload

echo "==> Creating post-GUI setup script..."
INSTALL_DIR="/var/www/html/phpipam"
cat > "$INSTALL_DIR/post-gui-setup.sh" <<EOP
#!/bin/bash
CONFIG_FILE="/var/www/html/phpipam/config.php"
if [ ! -f "\$CONFIG_FILE" ]; then
    echo "Error: \$CONFIG_FILE does not exist."
    exit 1
fi
if ! test -w "\$CONFIG_FILE"; then
    echo "Error: \$CONFIG_FILE is not writable. Check permissions."
    exit 1
fi
if grep -q 'disable_installer' "\$CONFIG_FILE"; then
    sed -i 's/\$disable_installer *= *false;/\$disable_installer = true;/' "\$CONFIG_FILE"
    if grep -q '\$disable_installer = true;' "\$CONFIG_FILE"; then
        echo "Installation script disabled in config.php"
    else
        echo "Error: Failed to update \$disable_installer in \$CONFIG_FILE."
        exit 1
    fi
else
    echo "disable_installer setting not found in config.php"
    exit 1
fi
EOP

chmod +x "$INSTALL_DIR/post-gui-setup.sh"
echo "Post-GUI setup script created at $INSTALL_DIR/post-gui-setup.sh"

SERVER_IP=$(hostname -I | awk '{print $1}')
echo
echo "  INSTALLATION COMPLETE"
echo "--------------------------------------------------"
echo "Access phpIPAM in your browser at: http://$SERVER_IP"
echo
echo "  AFTER completing the GUI installer, run:"
echo "   bash $INSTALL_DIR/post-gui-setup.sh"
echo "--------------------------------------------------"
