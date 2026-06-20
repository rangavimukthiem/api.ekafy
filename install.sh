#!/bin/bash

set -e

ROOT_DIR=/srv/ekafy


echo "==================================================================="
echo "   EKAFY SERVER INSTALLER v1 API Engine nginx|postgre|django REST"
echo "==================================================================="

# -----------------------------
# 1. SYSTEM UPDATE
# -----------------------------
echo "[1/10] Updating system..."
apt update && apt upgrade -y

# -----------------------------
# 2. CORE PACKAGES
# -----------------------------
echo "[2/10] Installing dependencies..."
apt install -y python3 python3-pip python3-venv git nginx curl ufw

# PostgreSQL
apt install -y postgresql postgresql-contrib

# -----------------------------
# 3. CREATE SYSTEM USER
# -----------------------------
echo "[3/10] Creating ekafy user..."
id -u ekafy &>/dev/null || useradd -m -s /bin/bash ekafy

# -----------------------------
# 4. PROJECT DIRECTORY
# -----------------------------
echo "[4/10] Creating project directory..."
mkdir -p $ROOT_DIR
chown -R ekafy:ekafy $ROOT_DIR

# -----------------------------
# 5. CLONE PROJECT
# -----------------------------
echo "[5/10] Validating Git + GitHub access..."

# 1. Git check
if ! command -v git &> /dev/null; then
    echo "Git not installed. Installing..."
    apt install -y git
fi

# 2. GitHub connectivity check
if ! curl -s --head https://github.com | grep "200" > /dev/null; then
    echo "ERROR: Cannot reach GitHub"
    exit 1
fi

# 3. Repo validation
echo "Checking repository access..."
if ! git ls-remote https://github.com/ekafy/core.git &> /dev/null; then
    echo "ERROR: Cannot access repository (wrong URL or private repo)"
    exit 1
fi

echo "Git validation OK"
# -----------------------------
# 5. CLONE PROJECT
# -----------------------------
echo "[5/10] Cloning backend..."
cd $ROOT_DIR
if ! sudo -u ekafy git clone https://github.com/rangavimukthiem/api.ekafy.git backend || true ; then 
    sudo -u ekafy git clone git@github.com:rangavimukthiem/api.ekafy.git backend || true 
    exit 0
fi






# -----------------------------
# 6. PYTHON ENV
# -----------------------------
echo "[6/10] Setting up virtual environment..."
cd $ROOT_DIR/backend
sudo -u ekafy python3 -m venv venv

sudo -u ekafy bash -c "source venv/bin/activate && pip install --upgrade pip"

if [ -f requirements.txt ]; then
    sudo -u ekafy bash -c "source venv/bin/activate && pip install -r requirements.txt"
fi

# -----------------------------
# 7. ENV FILE
# -----------------------------
echo "[7/10] Creating .env file..."

cat > $ROOT_DIR/backend/.env <<EOF
DEBUG=False
SECRET_KEY=change-this-secret
ALLOWED_HOSTS=*

DB_NAME=ekafy
DB_USER=ekafy
DB_PASSWORD=ekafy_pass
DB_HOST=localhost
DB_PORT=5432
EOF

chown ekafy:ekafy $ROOT_DIR/backend/.env

# -----------------------------
# 8. POSTGRES SETUP
# -----------------------------
echo "[8/10] Configuring PostgreSQL..."

sudo -u postgres psql <<EOF
CREATE DATABASE ekafy;
CREATE USER ekafy WITH PASSWORD 'ekafy_pass';
ALTER ROLE ekafy SET client_encoding TO 'utf8';
ALTER ROLE ekafy SET default_transaction_isolation TO 'read committed';
ALTER ROLE ekafy SET timezone TO 'UTC';
GRANT ALL PRIVILEGES ON DATABASE ekafy TO ekafy;
EOF

# -----------------------------
# 9. DJANGO SETUP
# -----------------------------
echo "[9/10] Running Django migrations..."

cd $ROOT_DIR/backend

sudo -u ekafy bash -c "source venv/bin/activate && python manage.py migrate"
sudo -u ekafy bash -c "source venv/bin/activate && python manage.py collectstatic --noinput"

# -----------------------------
# 10. GUNICORN SERVICE
# -----------------------------
echo "[10/10] Creating system service..."

cat > /etc/systemd/system/ekafy.service <<EOF
[Unit]
Description=Ekafy Django API
After=network.target

[Service]
User=ekafy
Group=www-data
WorkingDirectory=$ROOT_DIR/backend
EnvironmentFile=$ROOT_DIR/backend/.env

ExecStart=$ROOT_DIR/backend/venv/bin/gunicorn ekafy.wsgi:application \
--bind 127.0.0.1:8000 \
--workers 3

Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ekafy
systemctl start ekafy

# -----------------------------
# 11. NGINX CONFIG
# -----------------------------
echo "Configuring Nginx..."

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
# 12. FIREWALL
# -----------------------------
echo "Configuring firewall..."

ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

# -----------------------------
# DONE
# -----------------------------
echo "======================================"
echo " EKAFY INSTALLATION COMPLETE"
echo " API running on port 80"
echo "======================================"
