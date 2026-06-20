#!/bin/bash

set -e
DEBIAN_FRONTEND=noninteractive

trap 'echo "❌ INSTALL FAILED at line $LINENO"' ERR

LOGFILE="/var/log/ekafy-install.log"
exec > >(tee -a $LOGFILE) 2>&1

echo "==================================================================="
echo "   EKAFY SERVER INSTALLER v1 (FIXED & SAFE)"
echo "==================================================================="

# -----------------------------
# 1. SYSTEM UPDATE
# -----------------------------
echo "[1/12] Updating system..."
apt update && apt upgrade -y

# -----------------------------
# 2. CORE PACKAGES
# -----------------------------
echo "[2/12] Installing dependencies..."
apt install -y python3 python3-pip python3-venv git nginx curl ufw postgresql postgresql-contrib

# Ensure gunicorn support tools
apt install -y build-essential libpq-dev

# -----------------------------
# 3. CREATE SYSTEM USER
# -----------------------------
echo "[3/12] Creating ekafy user..."
id -u ekafy &>/dev/null || useradd -m -s /bin/bash ekafy

# -----------------------------
# 4. PROJECT DIRECTORY
# -----------------------------
echo "[4/12] Creating project directory..."
mkdir -p /srv/ekafy
chown -R ekafy:ekafy /srv/ekafy

# -----------------------------
# 5. GIT VALIDATION + CLONE
# -----------------------------
echo "[5/12] Checking Git + cloning backend..."

if ! command -v git &> /dev/null; then
    apt install -y git
fi

if ! curl -s --head https://github.com | grep "200" > /dev/null; then
    echo "❌ Cannot reach GitHub"
    exit 1
fi

cd /srv/ekafy

if [ ! -d "/srv/ekafy/backend/.git" ]; then
    sudo -u ekafy git clone https://github.com/ekafy/core.git backend
else
    echo "✔ Repo already exists, pulling latest..."
    sudo -u ekafy git -C backend pull
fi

# -----------------------------
# 6. PYTHON ENV
# -----------------------------
echo "[6/12] Setting up Python environment..."
cd /srv/ekafy/backend

sudo -u ekafy python3 -m venv venv

sudo -u ekafy bash -c "source venv/bin/activate && pip install --upgrade pip"

if [ -f requirements.txt ]; then
    sudo -u ekafy bash -c "source venv/bin/activate && pip install -r requirements.txt"
fi

sudo -u ekafy bash -c "source venv/bin/activate && pip install gunicorn"

# -----------------------------
# 7. GENERATE SECRET KEY
# -----------------------------
echo "[7/12] Creating .env file..."

SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(50))")

cat > /srv/ekafy/backend/.env <<EOF
DEBUG=False
SECRET_KEY=$SECRET_KEY
ALLOWED_HOSTS=*

DB_NAME=ekafy
DB_USER=ekafy
DB_PASSWORD=ekafy_pass
DB_HOST=localhost
DB_PORT=5432
EOF

chown ekafy:ekafy /srv/ekafy/backend/.env

# -----------------------------
# 8. POSTGRES SETUP (SAFE)
# -----------------------------
echo "[8/12] Configuring PostgreSQL..."

sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='ekafy'" | grep -q 1 || \
sudo -u postgres psql <<EOF
CREATE DATABASE ekafy;
EOF

sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='ekafy'" | grep -q 1 || \
sudo -u postgres psql <<EOF
CREATE USER ekafy WITH PASSWORD 'ekafy_pass';
ALTER ROLE ekafy SET client_encoding TO 'utf8';
ALTER ROLE ekafy SET default_transaction_isolation TO 'read committed';
ALTER ROLE ekafy SET timezone TO 'UTC';
GRANT ALL PRIVILEGES ON DATABASE ekafy TO ekafy;
EOF

# -----------------------------
# 9. DJANGO SETUP (SAFE)
# -----------------------------
echo "[9/12] Running Django setup..."

cd /srv/ekafy/backend

if [ -f "manage.py" ]; then
    sudo -u ekafy bash -c "source venv/bin/activate && python manage.py migrate"
    sudo -u ekafy bash -c "source venv/bin/activate && python manage.py collectstatic --noinput"
else
    echo "❌ manage.py not found - invalid backend repo"
    exit 1
fi

# -----------------------------
# 10. SYSTEMD SERVICE
# -----------------------------
echo "[10/12] Creating systemd service..."

cat > /etc/systemd/system/ekafy.service <<EOF
[Unit]
Description=Ekafy Django API
After=network.target

[Service]
User=ekafy
Group=www-data
WorkingDirectory=/srv/ekafy/backend
EnvironmentFile=/srv/ekafy/backend/.env

ExecStart=/srv/ekafy/backend/venv/bin/gunicorn ekafy.wsgi:application --bind 127.0.0.1:8000 --workers 3

Restart=always
RestartSec=5

NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ekafy
systemctl restart ekafy

# -----------------------------
# 11. NGINX CONFIG
# -----------------------------
echo "[11/12] Configuring Nginx..."

rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/ekafy <<EOF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

ln -sf /etc/nginx/sites-available/ekafy /etc/nginx/sites-enabled/

systemctl restart nginx

# -----------------------------
# 12. FIREWALL (SAFE ORDER)
# -----------------------------
echo "[12/12] Configuring firewall..."

ufw allow OpenSSH
ufw allow 22
ufw allow 'Nginx Full'
ufw --force enable

# -----------------------------
# DONE
# -----------------------------
echo "==================================================================="
echo " EKAFY INSTALLATION COMPLETE"
echo " API running on port 80"
echo " LOG: $LOGFILE"
echo "==================================================================="
