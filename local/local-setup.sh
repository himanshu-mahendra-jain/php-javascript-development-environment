#!/bin/bash

# Exit on error, on unset variable, and on pipeline failure.
set -euo pipefail

# Define vars
LOG_FILE="/var/log/phpjs-dev-environment-setup.log"
CURL_OPTS="--connect-timeout 15"
REQUIRED_DISK_GB=5

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Graceful exit function
exit_gracefully() {
    log "⚠️ Critical error occurred. Exiting setup."
    exit 1
}

# --- 1. Initial Sanity Checks ---
log "🚀 Starting system setup..."

# Check if running as root
if [[ "${EUID}" -ne 0 ]]; then
    log "❌ This script must be run as root. Please use 'sudo'."
    exit_gracefully
fi

# Check if SUDO_USER is set, needed for Git configuration
if [[ -z "$SUDO_USER" ]]; then
    log "⚠️  Cannot determine the original user. Git configuration will be skipped."
    GIT_CONFIG_SKIPPED=true
else
    GIT_CONFIG_SKIPPED=false
fi

# --- 2. Prerequisite Check ---
log "🔍 Checking for APT package manager..."
if ! command -v apt &> /dev/null; then
    log "❌ This script requires the 'apt' package manager and cannot continue."
    exit_gracefully
fi
log "👍 APT command found."

# --- 3. System Resource Check ---
log "🔍 Checking for sufficient disk space..."
# Get available disk space in Gigabytes on the root partition
AVAILABLE_GB=$(df --output=avail / | tail -n 1)
# Convert to an integer by dividing by 1024*1024
AVAILABLE_GB=$((AVAILABLE_GB / 1024 / 1024))

if (( AVAILABLE_GB < REQUIRED_DISK_GB )); then
    log "❌ Insufficient disk space. Requires ~${REQUIRED_DISK_GB}GB, but only ${AVAILABLE_GB}GB is available."
    exit_gracefully
fi
log "👍 Available disk space: ${AVAILABLE_GB}GB. Proceeding..."

# --- 4. Configure gai.conf for IPv4 precedence ---
if ! grep -qF "precedence ::ffff:0:0/96 100" /etc/gai.conf; then
    log "🔧 Setting IPv4-mapped IPv6 addresses to default precedence..."
    echo "precedence ::ffff:0:0/96 100" | tee -a /etc/gai.conf
else
    log "👍 IPv4 precedence already set in /etc/gai.conf."
fi

# --- 5. Standard System Update ---
log "ℹ️ Performing standard system update..."
apt update
apt upgrade -y

# --- 6. Install Essential Packages ---
log "📦 Installing essential packages..."
apt install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    gnupg2 \
    zip

# --- 7. Install Visual Studio Code ---
if ! command -v code &> /dev/null; then
    log "📦 Installing Visual Studio Code..."
    # Ensure the keyrings directory exists
    mkdir -p /etc/apt/keyrings
    # Add the Microsoft GPG key
    curl $CURL_OPTS -sSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /etc/apt/keyrings/microsoft.gpg
    # Add the VS Code repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" > /etc/apt/sources.list.d/vscode.list
    apt update
    apt install -y code
else
    log "👍 Visual Studio Code is already installed."
fi

# --- 8. Install Node.js (always Current), NPM, and PNPM ---
log "🔧 Installing latest Node.js 'Current' release..."
curl -fsSL https://deb.nodesource.com/setup_current.x | bash -
apt install -y --no-install-recommends nodejs

# Upgrade npm
log "Upgrading npm globally..."
npm install -g npm@latest

log "📦 Installing pnpm globally..."
npm install -g pnpm

if [[ -n "$SUDO_USER" ]]; then
    USER_HOME=$(eval echo "~$SUDO_USER")
    PNPM_BIN_DIR="$USER_HOME/.local/share/pnpm"

    # Ensure target user's directories exist with correct permissions
    mkdir -p "$PNPM_BIN_DIR" "$PNPM_BIN_DIR/bin"
    chown -R "$SUDO_USER:" "$USER_HOME/.local"

    # Add PNPM_HOME and bin path to user's .bashrc if not already present
    if ! grep -q "PNPM_HOME" "$USER_HOME/.bashrc" 2>/dev/null; then
        echo -e '\n# pnpm\nexport PNPM_HOME="$HOME/.local/share/pnpm"\nexport PATH="$PNPM_HOME:$PNPM_HOME/bin:$PATH"' >> "$USER_HOME/.bashrc"
        chown "$SUDO_USER:" "$USER_HOME/.bashrc"
    fi

    # Install Playwright globally for the user
    log "📦 Installing Playwright globally for user '$SUDO_USER'..."
    sudo -u "$SUDO_USER" -H bash -c "export PNPM_HOME=\"$PNPM_BIN_DIR\" && export PATH=\"\$PNPM_HOME:\$PNPM_HOME/bin:\$PATH\" && pnpm add -g @playwright/test"

    # Install browser binaries and OS dependencies
    npx -y playwright install --with-deps

    log "👍 Playwright and its browsers installed globally."
    log "ℹ️ A new terminal session may be needed for 'pnpm' and 'playwright' commands to be available in your path."
else
    log "⚠️ Could not determine original user. Skipping user-specific Playwright installation."
fi

# --- 9. Install PHP and Extensions ---
log "📦 Installing PHP and required extensions..."
apt install -y --no-install-recommends \
    php php-bcmath php-calendar php-cli php-common php-ctype php-curl php-dom \
    php-exif php-fileinfo php-ftp php-gd php-gmp php-iconv php-intl php-ldap \
    php-mbstring php-mysqli php-mysqlnd php-opcache php-pdo php-pgsql php-posix \
    php-readline php-simplexml php-soap php-sockets php-sqlite3 php-sysvsem \
    php-tokenizer php-xml php-xmlreader php-xmlwriter php-zip

# --- 10. Install Composer ---
log "📦 Installing Composer..."
EXPECTED_CHECKSUM="$(curl $CURL_OPTS -sS https://composer.github.io/installer.sig)"
php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
    log '❌ ERROR: Invalid Composer installer checksum'
    rm -f composer-setup.php
    exit_gracefully
else
    php composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f composer-setup.php
    log "👍 Composer installed successfully."
fi

# --- 11. Configure Git for the User (skip if already configured) ---
if [[ -n "$SUDO_USER" && "$GIT_CONFIG_SKIPPED" = false ]]; then
    if sudo -u "$SUDO_USER" git config --global user.name &>/dev/null && \
       sudo -u "$SUDO_USER" git config --global user.email &>/dev/null; then
        log "ℹ️ Git is already configured for user '$SUDO_USER'. Skipping configuration."
    else
        read -p "Enter your full name for Git: " git_name
        read -p "Enter your email for Git: " git_email

        log "🔧 Configuring Git for user '$SUDO_USER'..."
        sudo -u $SUDO_USER git config --global user.name "$git_name"
        sudo -u $SUDO_USER git config --global user.email "$git_email"
        sudo -u $SUDO_USER git config --global credential.helper 'cache --timeout=2592000'
        log "👍 Git has been configured."
    fi
else
    log "Skipping Git configuration because the original user could not be determined."
fi

# --- 12. Enable Wayland support for Electron apps ---
log "Adding ELECTRON_OZONE_PLATFORM_HINT=auto to /etc/environment..."

if ! grep -q '^ELECTRON_OZONE_PLATFORM_HINT=auto' /etc/environment; then
    echo 'ELECTRON_OZONE_PLATFORM_HINT=auto' | tee -a /etc/environment > /dev/null
    log "✅ Added ELECTRON_OZONE_PLATFORM_HINT to /etc/environment."
else
    log "ℹ️ ELECTRON_OZONE_PLATFORM_HINT already present in /etc/environment."
fi

# --- 13. Clean Up ---
log "🧹 Cleaning up..."
apt autoremove -y
apt clean -y
rm -rf /tmp/* /var/tmp/*

# --- 14. Final Message ---
log "✅ System setup is complete!"
log "A reboot is recommended to ensure all changes take effect."
log "You can reboot now by running: sudo reboot"
