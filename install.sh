#!/usr/bin/env bash
# =============================================================================
#  EKAFY HYBRID CONTROL SYSTEM — PRODUCTION INSTALLER v2.0
#  One-command installer for fresh Ubuntu 22.04 / 24.04 VPS
#
#  Usage:
#    curl -s https://install.ekafy.com | bash
#    -- OR --
#    bash install.sh
#
#  Idempotent: safe to re-run on existing installation.
#  All actions logged to: /var/log/ekafy-install.log
# =============================================================================

set -euo pipefail
DEBIAN_FRONTEND=noninteractive

# ─── GLOBAL CONFIG ────────────────────────────────────────────────────────────
readonly EKAFY_VERSION="2.0.0"
readonly EKAFY_USER="ekafy"
readonly EKAFY_GROUP="www-data"
readonly EKAFY_BASE="/srv/ekafy"
readonly BACKEND_DIR="${EKAFY_BASE}/backend"
readonly WP_DIR="${EKAFY_BASE}/wordpress"
readonly LOGS_DIR="${EKAFY_BASE}/logs"
readonly LOGFILE="/var/log/ekafy-install.log"

readonly GITHUB_SSH_BACKEND="git@github.com:ekafy/core.git"
readonly GUNICORN_PORT="8000"
readonly PHP_VERSION="8.2"

# ─── COLORS ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── LOGGING ──────────────────────────────────────────────────────────────────
# Ensure log directory exists before redirecting
mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"
exec > >(tee -a "$LOGFILE") 2>&1

log_info()    { echo -e "${GREEN}[INFO]${RESET}  $(date '+%H:%M:%S') — $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $(date '+%H:%M:%S') — $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $(date '+%H:%M:%S') — $*"; }
log_step()    { echo -e "\n${BLUE}${BOLD}━━━ $* ━━━${RESET}"; }
log_done()    { echo -e "${CYAN}[DONE]${RESET}  $*"; }

# ─── ERROR HANDLER ────────────────────────────────────────────────────────────
trap 'handle_error $LINENO' ERR

handle_error() {
    local line="$1"
    log_error "Installation failed at line ${line}."
    log_error "Check full log: ${LOGFILE}"
    log_error "Run with EKAFY_DEBUG=1 bash install.sh for verbose output."
    exit 1
}

# ─── HELPERS ──────────────────────────────────────────────────────────────────
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "This installer must be run as root (or with sudo)."
        exit 1
    fi
}

check_ubuntu() {
    if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
        log_error "This installer supports Ubuntu only (22.04 / 24.04)."
        exit 1
    fi
    local version
    version=$(grep VERSION_ID /etc/os-release | cut -d '"' -f2)
    log_info "Detected Ubuntu ${version}"
    if [[ "${version}" != "22.04" && "${version}" != "24.04" ]]; then
        log_warn "Untested Ubuntu version ${version} — proceeding anyway."
    fi
}

check_internet() {
    log_info "Checking internet connectivity..."
    if ! curl -s --max-time 5 --head https://api.github.com > /dev/null 2>&1; then
        log_error "Cannot reach GitHub. Check network and DNS."
        exit 1
    fi
    log_done "Internet reachable."
}

check_ssh_key() {
    log_info "Checking SSH key for GitHub access..."
    local key_found=0
    # Check root SSH keys
    for key_file in ~/.ssh/id_ed25519 ~/.ssh/id_rsa ~/.ssh/id_ecdsa; do
        if [[ -f "${key_file}" ]]; then
            key_found=1
            log_done "SSH key found: ${key_file}"
            break
        fi
    done

    if [[ "${key_found}" -eq 0 ]]; then
        log_warn "No SSH private key found at ~/.ssh/. Generating ed25519 key..."
        mkdir -p ~/.ssh
        chmod 700 ~/.ssh
        ssh-keygen -t ed25519 -C "ekafy-deploy@$(hostname)" -f ~/.ssh/id_ed25519 -N ""
        log_warn "═══════════════════════════════════════════════════════════"
        log_warn " IMPORTANT: Add this public key to your GitHub repository:"
        log_warn "═══════════════════════════════════════════════════════════"
        cat ~/.ssh/id_ed25519.pub
        log_warn "═══════════════════════════════════════════════════════════"
        read -rp "Press ENTER after adding the deploy key to GitHub..."
    fi

    # Add GitHub to known_hosts
    ssh-keyscan -H github.com >> ~/.ssh/known_hosts 2>/dev/null
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

idempotent_dir() {
    [[ -d "$1" ]] || mkdir -p "$1"
}

# ─── STEP 1: SYSTEM UPDATE ────────────────────────────────────────────────────
step_system_update() {
    log_step "Step 1/12 — System Update"
    apt-get update -qq
    apt-get upgrade -y -qq
    log_done "System packages updated."
}

# ─── STEP 2: CORE DEPENDENCIES ───────────────────────────────────────────────
step_install_dependencies() {
    log_step "Step 2/12 — Core Dependencies"

    # Python + build tools
    apt-get install -y -qq \
        python3 python3-pip python3-venv python3-dev \
        build-essential libpq-dev libssl-dev libffi-dev \
        git curl wget unzip gnupg2 software-properties-common \
        ufw

    # Nginx
    apt-get install -y -qq nginx

    # PostgreSQL
    if ! command_exists psql; then
        apt-get install -y -qq postgresql postgresql-contrib
    fi

    # MySQL/MariaDB for WordPress
    if ! command_exists mysql; then
        apt-get install -y -qq mariadb-server mariadb-client
    fi

    # PHP + FPM for WordPress
    if ! command_exists php; then
        add-apt-repository -y ppa:ondrej/php
        apt-get update -qq
    fi
    apt-get install -y -qq \
        "php${PHP_VERSION}" "php${PHP_VERSION}-fpm" \
        "php${PHP_VERSION}-mysql" "php${PHP_VERSION}-curl" \
        "php${PHP_VERSION}-gd" "php${PHP_VERSION}-mbstring" \
        "php${PHP_VERSION}-xml" "php${PHP_VERSION}-zip" \
        "php${PHP_VERSION}-intl" "php${PHP_VERSION}-bcmath"

    # Redis (optional but recommended for caching)
    if ! command_exists redis-cli; then
        apt-get install -y -qq redis-server
        systemctl enable redis-server
        systemctl start redis-server
    fi

    log_done "All dependencies installed."
}

# ─── STEP 3: SYSTEM USER ─────────────────────────────────────────────────────
step_create_user() {
    log_step "Step 3/12 — System User"

    if ! id -u "${EKAFY_USER}" &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin \
                --gid "${EKAFY_GROUP}" "${EKAFY_USER}"
        log_done "User '${EKAFY_USER}' created."
    else
        log_info "User '${EKAFY_USER}' already exists."
    fi

    # Allow ekafy user to run specific systemctl commands via sudo (no password)
    local sudoers_file="/etc/sudoers.d/ekafy-services"
    cat > "${sudoers_file}" <<'SUDOERS'
# Ekafy service control — allow dashboard to restart services safely
ekafy ALL=(ALL) NOPASSWD: /bin/systemctl restart ekafy, \
                            /bin/systemctl start ekafy, \
                            /bin/systemctl stop ekafy, \
                            /bin/systemctl restart nginx, \
                            /bin/systemctl restart postgresql, \
                            /bin/systemctl restart redis, \
                            /bin/systemctl restart php8.2-fpm
SUDOERS
    chmod 440 "${sudoers_file}"
    visudo -cf "${sudoers_file}" && log_done "Sudoers rule validated." || {
        log_error "Sudoers syntax error — removing"
        rm "${sudoers_file}"
    }
}

# ─── STEP 4: DIRECTORY STRUCTURE ─────────────────────────────────────────────
step_create_directories() {
    log_step "Step 4/12 — Directory Structure"

    idempotent_dir "${EKAFY_BASE}"
    idempotent_dir "${BACKEND_DIR}"
    idempotent_dir "${WP_DIR}"
    idempotent_dir "${LOGS_DIR}"

    chown -R "${EKAFY_USER}:${EKAFY_GROUP}" "${EKAFY_BASE}"
    chmod -R 755 "${EKAFY_BASE}"
    chmod 775 "${LOGS_DIR}"

    log_done "Directory structure created at ${EKAFY_BASE}/"
}

# ─── STEP 5: GIT CLONE (SSH) ─────────────────────────────────────────────────
step_clone_backend() {
    log_step "Step 5/12 — Clone Backend (SSH)"

    if [[ -d "${BACKEND_DIR}/.git" ]]; then
        log_info "Backend repo exists — pulling latest..."
        git -C "${BACKEND_DIR}" pull --rebase
    else
        log_info "Cloning backend from ${GITHUB_SSH_BACKEND}..."
        git clone --depth 1 "${GITHUB_SSH_BACKEND}" "${BACKEND_DIR}"
    fi

    chown -R "${EKAFY_USER}:${EKAFY_GROUP}" "${BACKEND_DIR}"
    log_done "Backend code ready at ${BACKEND_DIR}/"
}

# ─── STEP 6: PYTHON VIRTUAL ENV ──────────────────────────────────────────────
step_python_env() {
    log_step "Step 6/12 — Python Virtual Environment"

    if [[ ! -d "${BACKEND_DIR}/venv" ]]; then
        python3 -m venv "${BACKEND_DIR}/venv"
    fi

    # Upgrade pip
    "${BACKEND_DIR}/venv/bin/pip" install --upgrade pip --quiet

    # Install requirements
    if [[ -f "${BACKEND_DIR}/requirements.txt" ]]; then
        "${BACKEND_DIR}/venv/bin/pip" install -r "${BACKEND_DIR}/requirements.txt" --quiet
        log_done "Python dependencies installed."
    else
        log_warn "requirements.txt not found — skipping pip install."
    fi

    # Always ensure gunicorn is present
    "${BACKEND_DIR}/venv/bin/pip" install gunicorn --quiet

    chown -R "${EKAFY_USER}:${EKAFY_GROUP}" "${BACKEND_DIR}/venv"
    log_done "Virtual environment ready."
}

# ─── STEP 7: ENV FILE ─────────────────────────────────────────────────────────
step_create_env() {
    log_step "Step 7/12 — Environment Configuration"

    local env_file="${BACKEND_DIR}/.env"

    if [[ -f "${env_file}" ]]; then
        log_info ".env already exists — skipping regeneration."
        return
    fi

    # Generate strong secret key
    local secret_key
    secret_key=$(python3 -c "import secrets; print(secrets.token_urlsafe(50))")

    # Generate random DB password
    local db_pass
    db_pass=$(python3 -c "import secrets; print(secrets.token_hex(16))")

    cat > "${env_file}" <<EOF
DEBUG=False
SECRET_KEY=${secret_key}
ALLOWED_HOSTS=api.ekafy.com,dashboard.ekafy.com,127.0.0.1,localhost

DB_NAME=ekafy
DB_USER=ekafy
DB_PASSWORD=${db_pass}
DB_HOST=localhost
DB_PORT=5432

REDIS_URL=redis://127.0.0.1:6379/1

JWT_ACCESS_MINUTES=60
JWT_REFRESH_DAYS=7

CORS_ALLOWED_ORIGINS=https://dashboard.ekafy.com

TIME_ZONE=UTC
LOG_LEVEL=INFO
LOG_FILE=${LOGS_DIR}/django.log
FORCE_HTTPS=False
MONITORING_LOG_LINES=100
EOF

    chown "${EKAFY_USER}:${EKAFY_GROUP}" "${env_file}"
    chmod 600 "${env_file}"
    log_done ".env created. DB_PASSWORD stored — save it from ${env_file}"
}

# ─── STEP 8: POSTGRESQL ───────────────────────────────────────────────────────
step_setup_postgres() {
    log_step "Step 8/12 — PostgreSQL Setup"

    systemctl enable postgresql
    systemctl start postgresql

    # Read DB credentials from .env
    local db_name db_user db_pass
    db_name=$(grep '^DB_NAME=' "${BACKEND_DIR}/.env" | cut -d= -f2)
    db_user=$(grep '^DB_USER=' "${BACKEND_DIR}/.env" | cut -d= -f2)
    db_pass=$(grep '^DB_PASSWORD=' "${BACKEND_DIR}/.env" | cut -d= -f2)

    # Idempotent: create role + DB only if not exists
    sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${db_user}'" | grep -q 1 || \
    sudo -u postgres psql <<PSQL
CREATE USER ${db_user} WITH PASSWORD '${db_pass}';
ALTER ROLE ${db_user} SET client_encoding TO 'utf8';
ALTER ROLE ${db_user} SET default_transaction_isolation TO 'read committed';
ALTER ROLE ${db_user} SET timezone TO 'UTC';
PSQL

    sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${db_name}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE DATABASE ${db_name} OWNER ${db_user};"

    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${db_name} TO ${db_user};"

    log_done "PostgreSQL database '${db_name}' ready."
}

# ─── STEP 9: DJANGO SETUP ─────────────────────────────────────────────────────
step_django_setup() {
    log_step "Step 9/12 — Django Setup"

    if [[ ! -f "${BACKEND_DIR}/manage.py" ]]; then
        log_error "manage.py not found in ${BACKEND_DIR} — invalid backend repository."
        exit 1
    fi

    local py="${BACKEND_DIR}/venv/bin/python"
    local manage="${BACKEND_DIR}/manage.py"

    # Export .env variables for Django commands
    set -a
    source "${BACKEND_DIR}/.env"
    set +a

    # Migrations
    "${py}" "${manage}" migrate --noinput
    log_done "Database migrations applied."

    # Collect static files
    "${py}" "${manage}" collectstatic --noinput --clear
    log_done "Static files collected."

    # Load initial product data (idempotent)
    if [[ -f "${BACKEND_DIR}/apps/products/fixtures/load_initial.py" ]]; then
        "${py}" "${manage}" shell < "${BACKEND_DIR}/apps/products/fixtures/load_initial.py"
    fi

    chown -R "${EKAFY_USER}:${EKAFY_GROUP}" "${BACKEND_DIR}"
    log_done "Django configured."
}

# ─── STEP 10: WORDPRESS ───────────────────────────────────────────────────────
step_wordpress_setup() {
    log_step "Step 10/12 — WordPress Setup"

    # WordPress DB credentials
    local wp_db_name="ekafy_wp"
    local wp_db_user="ekafy_wp"
    local wp_db_pass
    wp_db_pass=$(python3 -c "import secrets; print(secrets.token_hex(12))")

    # Setup MySQL/MariaDB
    systemctl enable mariadb
    systemctl start mariadb

    mysql -e "CREATE DATABASE IF NOT EXISTS ${wp_db_name} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || true
    mysql -e "CREATE USER IF NOT EXISTS '${wp_db_user}'@'localhost' IDENTIFIED BY '${wp_db_pass}';" 2>/dev/null || true
    mysql -e "GRANT ALL PRIVILEGES ON ${wp_db_name}.* TO '${wp_db_user}'@'localhost';" 2>/dev/null || true
    mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    log_done "WordPress MariaDB database ready."

    # Download and extract WordPress (if not already present)
    if [[ ! -f "${WP_DIR}/wp-config.php" && ! -f "${WP_DIR}/index.php" ]]; then
        wget -qO /tmp/wordpress.tar.gz https://wordpress.org/latest.tar.gz
        tar -xzf /tmp/wordpress.tar.gz -C /tmp/
        rsync -a /tmp/wordpress/ "${WP_DIR}/"
        rm -f /tmp/wordpress.tar.gz
        rm -rf /tmp/wordpress

        # Create wp-config.php
        cp "${WP_DIR}/wp-config-sample.php" "${WP_DIR}/wp-config.php"
        sed -i "s/database_name_here/${wp_db_name}/" "${WP_DIR}/wp-config.php"
        sed -i "s/username_here/${wp_db_user}/"      "${WP_DIR}/wp-config.php"
        sed -i "s/password_here/${wp_db_pass}/"      "${WP_DIR}/wp-config.php"
        sed -i "s/localhost/localhost/"               "${WP_DIR}/wp-config.php"

        # Generate unique WordPress salts
        local wp_salts
        wp_salts=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
        # Replace placeholder salt block
        python3 -c "
import re, sys
config = open('${WP_DIR}/wp-config.php').read()
salt_start = config.find(\"define( 'AUTH_KEY'\")
salt_end   = config.find(\"define( 'NONCE_SALT'\") + len(\"define( 'NONCE_SALT', '' );\")
new_salts  = '''${wp_salts}'''
config = config[:salt_start] + new_salts + config[salt_end:]
open('${WP_DIR}/wp-config.php', 'w').write(config)
" 2>/dev/null || log_warn "Could not auto-insert WordPress salts. Edit wp-config.php manually."

        log_done "WordPress installed to ${WP_DIR}/"
    else
        log_info "WordPress already installed — skipping download."
    fi

    # Set correct permissions
    chown -R "${EKAFY_USER}:${EKAFY_GROUP}" "${WP_DIR}"
    find "${WP_DIR}" -type d -exec chmod 755 {} \;
    find "${WP_DIR}" -type f -exec chmod 644 {} \;
    chmod 600 "${WP_DIR}/wp-config.php"

    # Save WP credentials
    cat >> "${EKAFY_BASE}/logs/wp-credentials.txt" <<WP_CREDS
WordPress DB Setup ($(date))
  DB Name:     ${wp_db_name}
  DB User:     ${wp_db_user}
  DB Password: ${wp_db_pass}
  DB Host:     localhost
WP_CREDS
    chmod 600 "${EKAFY_BASE}/logs/wp-credentials.txt"

    log_done "WordPress credentials saved to ${EKAFY_BASE}/logs/wp-credentials.txt"
    log_warn "Complete WordPress setup by visiting https://blog.ekafy.com/wp-admin/install.php"
}

# ─── STEP 11: SYSTEMD ─────────────────────────────────────────────────────────
step_systemd() {
    log_step "Step 11/12 — Systemd Services"

    # Gunicorn service
    cat > /etc/systemd/system/ekafy.service <<SERVICE
[Unit]
Description=Ekafy Django API + Dashboard (Gunicorn)
After=network.target postgresql.service redis.service
Wants=postgresql.service

[Service]
User=${EKAFY_USER}
Group=${EKAFY_GROUP}
WorkingDirectory=${BACKEND_DIR}
EnvironmentFile=${BACKEND_DIR}/.env

ExecStart=${BACKEND_DIR}/venv/bin/gunicorn \\
    ekafy.wsgi:application \\
    --bind 127.0.0.1:${GUNICORN_PORT} \\
    --workers 3 \\
    --worker-class sync \\
    --max-requests 1000 \\
    --max-requests-jitter 50 \\
    --timeout 30 \\
    --keep-alive 5 \\
    --access-logfile ${LOGS_DIR}/gunicorn.log \\
    --error-logfile ${LOGS_DIR}/gunicorn-error.log \\
    --log-level warning \\
    --capture-output

ExecReload=/bin/kill -s HUP \$MAINPID
Restart=always
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=3

NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ReadWritePaths=${EKAFY_BASE} /var/log
ProtectHome=true

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable ekafy
    systemctl restart ekafy
    log_done "ekafy.service enabled and started."

    # Start PHP-FPM for WordPress
    systemctl enable "php${PHP_VERSION}-fpm"
    systemctl restart "php${PHP_VERSION}-fpm"
    log_done "php${PHP_VERSION}-fpm started."
}

# ─── STEP 12: NGINX ───────────────────────────────────────────────────────────
step_nginx() {
    log_step "Step 12/12 — Nginx Configuration"

    local nginx_available="/etc/nginx/sites-available/ekafy"
    local nginx_enabled="/etc/nginx/sites-enabled/ekafy"
    local nginx_default="/etc/nginx/sites-enabled/default"

    # Remove default site
    [[ -f "${nginx_default}" ]] && rm -f "${nginx_default}"

    # Install nginx config from repo if available, else generate minimal config
    if [[ -f "${BACKEND_DIR}/../nginx/ekafy.conf" ]]; then
        cp "${BACKEND_DIR}/../nginx/ekafy.conf" "${nginx_available}"
        log_info "Nginx config copied from repository."
    else
        # Generate minimal config
        cat > "${nginx_available}" <<'NGINX'
upstream django_backend {
    server 127.0.0.1:8000;
    keepalive 32;
}
limit_req_zone $binary_remote_addr zone=api_limit:10m rate=60r/m;

server {
    listen 80;
    server_name api.ekafy.com dashboard.ekafy.com;
    client_max_body_size 10M;
    location /static/ {
        alias /srv/ekafy/backend/staticfiles/;
        expires 30d;
        access_log off;
    }
    location /nginx_status {
        stub_status on;
        allow 127.0.0.1;
        deny all;
    }
    location / {
        limit_req zone=api_limit burst=20 nodelay;
        proxy_pass http://django_backend;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Connection "";
    }
}

server {
    listen 80;
    server_name blog.ekafy.com;
    root /srv/ekafy/wordpress;
    index index.php index.html;
    location / { try_files $uri $uri/ /index.php?$args; }
    location ~ \.php$ {
        try_files $uri =404;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }
    location ~* /wp-config\.php { deny all; }
    location ~* /xmlrpc\.php    { deny all; }
}
NGINX
    fi

    ln -sf "${nginx_available}" "${nginx_enabled}"

    # Test config
    nginx -t && {
        systemctl enable nginx
        systemctl reload nginx
        log_done "Nginx reloaded successfully."
    } || {
        log_error "Nginx config test failed. Check ${nginx_available}"
        exit 1
    }
}

# ─── STEP 13: FIREWALL ────────────────────────────────────────────────────────
step_firewall() {
    log_step "Firewall — UFW"

    # CRITICAL: allow SSH first to prevent lockout
    ufw allow OpenSSH
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp

    # Enable non-interactively
    ufw --force enable
    log_done "UFW enabled: SSH (22), HTTP (80), HTTPS (443) allowed."
    ufw status
}

# ─── SSL SETUP GUIDE ─────────────────────────────────────────────────────────
print_ssl_instructions() {
    echo -e "\n${CYAN}${BOLD}━━━ SSL/TLS SETUP (Run after DNS is configured) ━━━${RESET}"
    echo -e "  Install Certbot:"
    echo -e "    ${YELLOW}apt install certbot python3-certbot-nginx -y${RESET}"
    echo -e "  Issue certificates:"
    echo -e "    ${YELLOW}certbot --nginx -d api.ekafy.com -d dashboard.ekafy.com -d blog.ekafy.com${RESET}"
    echo -e "  Auto-renew is configured automatically by Certbot."
    echo ""
}

# ─── FINAL VALIDATION ─────────────────────────────────────────────────────────
validate_installation() {
    log_step "Validation"

    local errors=0

    # Check systemd services
    for svc in ekafy nginx postgresql mariadb "php${PHP_VERSION}-fpm" redis; do
        if systemctl is-active --quiet "${svc}" 2>/dev/null; then
            log_done "✓ ${svc} is running"
        else
            log_warn "✗ ${svc} is NOT running (may be optional)"
            ((errors++)) || true
        fi
    done

    # Check Gunicorn responds
    if curl -s --max-time 3 http://127.0.0.1:8000/api/v1/ > /dev/null 2>&1; then
        log_done "✓ Django API responding on port 8000"
    else
        log_warn "✗ Django API not responding — check: journalctl -u ekafy"
        ((errors++)) || true
    fi

    # Check WordPress
    if [[ -f "${WP_DIR}/wp-config.php" ]]; then
        log_done "✓ WordPress installed at ${WP_DIR}"
    fi

    return "${errors}"
}

# ─── BANNER ───────────────────────────────────────────────────────────────────
print_banner() {
    echo -e "${BLUE}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║          EKAFY HYBRID CONTROL SYSTEM — INSTALLER v2.0       ║"
    echo "║      Django API · WordPress · Dashboard · Monitoring         ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

print_summary() {
    echo -e "\n${GREEN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                 INSTALLATION COMPLETE ✓                     ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo -e "║  API:        ${CYAN}http://api.ekafy.com${GREEN}                            ║"
    echo -e "║  Dashboard:  ${CYAN}http://dashboard.ekafy.com/dashboard/${GREEN}            ║"
    echo -e "║  Blog:       ${CYAN}http://blog.ekafy.com${GREEN}                           ║"
    echo -e "║  Log:        ${CYAN}${LOGFILE}${GREEN}                    ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  Next steps:                                                 ║"
    echo "║  1. Configure DNS A records for your domains                 ║"
    echo "║  2. Run certbot for SSL (see instructions above)             ║"
    echo "║  3. Create Django admin: python manage.py createsuperuser    ║"
    echo "║  4. Complete WordPress install at /wp-admin/install.php      ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

# ─── MAIN ─────────────────────────────────────────────────────────────────────
main() {
    print_banner

    check_root
    check_ubuntu
    check_internet
    check_ssh_key

    step_system_update
    step_install_dependencies
    step_create_user
    step_create_directories
    step_clone_backend
    step_python_env
    step_create_env
    step_setup_postgres
    step_django_setup
    step_wordpress_setup
    step_systemd
    step_nginx
    step_firewall

    validate_installation || true

    print_ssl_instructions
    print_summary

    log_info "Full installation log: ${LOGFILE}"
}

main "$@"
