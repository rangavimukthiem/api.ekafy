# EKAFY Hybrid Control System — Complete Architecture & Deployment Guide

> **Production-grade hybrid hosting platform** running Django REST API, WordPress, real-time server monitoring, and an admin dashboard — all on a single Linux VPS under one Nginx reverse proxy.

---

## Table of Contents
1. [System Architecture](#1-system-architecture)
2. [Django Project Structure](#2-django-project-structure)
3. [Monitoring System](#3-monitoring-system)
4. [Product Management Module](#4-product-management-module)
5. [Admin Dashboard](#5-admin-dashboard)
6. [WordPress Setup](#6-wordpress-setup)
7. [Nginx Configuration](#7-nginx-configuration)
8. [Systemd Services](#8-systemd-services)
9. [Installer Script](#9-installer-script)
10. [Security Configuration](#10-security-configuration)
11. [Deployment Guide](#11-deployment-guide)
12. [API Reference](#12-api-reference)

---

## 1. System Architecture

```
Internet
    │
    ▼
┌─────────────────────────────────────────────────────┐
│              Nginx (Reverse Proxy)                   │
│  Rate limiting · Security headers · SSL termination │
└──────────────────┬──────────────────────────────────┘
                   │
     ┌─────────────┼─────────────┐
     ▼             ▼             ▼
api.ekafy.com  blog.ekafy.com  dashboard.ekafy.com
     │             │                   │
     ▼             ▼                   ▼
 Gunicorn      PHP-FPM           Gunicorn (same)
 :8000         /run/php/         :8000 /dashboard/
     │         php8.2-fpm.sock
     ▼             ▼
 Django        WordPress
 REST API      + MySQL
     │
     ▼
 PostgreSQL + Redis
```

### Component Map

| Domain | Backend | Process | Port |
|--------|---------|---------|------|
| `api.ekafy.com` | Django DRF | Gunicorn | 8000 |
| `blog.ekafy.com` | WordPress | PHP-FPM | Unix socket |
| `dashboard.ekafy.com` | Django views | Gunicorn | 8000 |

### VPS Resource Allocation (2–4 GB RAM)

| Service | RAM Est. | CPU |
|---------|----------|-----|
| Gunicorn (3 workers) | ~300 MB | 30% |
| PostgreSQL | ~200 MB | 10% |
| Nginx | ~50 MB | 5% |
| WordPress + PHP-FPM | ~200 MB | 15% |
| Redis | ~50 MB | 2% |
| MariaDB | ~150 MB | 10% |
| **Total** | **~950 MB** | **~72%** |

---

## 2. Django Project Structure

```
/srv/ekafy/backend/
├── manage.py
├── requirements.txt
├── .env                    ← secrets (chmod 600, git-ignored)
├── .env.example            ← template (committed)
│
├── ekafy/                  ← project package
│   ├── settings.py         ← all config, env-driven
│   ├── urls.py             ← master URL router
│   ├── wsgi.py             ← Gunicorn entry point
│   └── asgi.py             ← async entry point
│
├── apps/
│   ├── products/           ← product management
│   │   ├── models.py       ← Product model
│   │   ├── serializers.py  ← DRF serializers
│   │   ├── views.py        ← ViewSet + custom actions
│   │   ├── urls.py         ← router registration
│   │   ├── admin.py        ← Django admin config
│   │   ├── migrations/
│   │   └── fixtures/
│   │       └── load_initial.py   ← seeds ONE real product
│   │
│   ├── monitoring/         ← real-time system metrics
│   │   ├── service.py      ← reads /proc, systemctl
│   │   ├── views.py        ← Admin-only REST endpoints
│   │   └── urls.py
│   │
│   ├── dashboard/          ← HTML admin dashboard
│   │   ├── views.py        ← staff-only views + AJAX
│   │   ├── urls.py
│   │   ├── service_control.py  ← systemctl allowlist wrapper
│   │   └── apps.py
│   │
│   └── system_config/      ← platform info API
│       ├── views.py
│       └── urls.py
│
├── templates/
│   └── dashboard/
│       ├── base.html       ← design system + sidebar
│       ├── index.html      ← live metrics dashboard
│       ├── login.html      ← staff login
│       ├── services.html   ← service control panel
│       ├── logs.html       ← log viewer
│       └── products.html   ← product table
│
├── static/                 ← source static files
├── staticfiles/            ← collectstatic output (git-ignored)
└── media/                  ← user uploads (git-ignored)
```

---

## 3. Monitoring System

All metrics are read from **real Linux system sources** — no mock data ever:

| Metric | Source |
|--------|--------|
| CPU usage % | `/proc/stat` (two reads, delta calculation) |
| RAM usage | `/proc/meminfo` |
| Disk usage | `shutil.disk_usage('/')` |
| Load average | `/proc/loadavg` |
| Uptime | `/proc/uptime` |
| TCP connections | `/proc/net/tcp` + `/proc/net/tcp6` |
| Service status | `systemctl is-active <service>` |
| Nginx connections | `http://127.0.0.1/nginx_status` (stub_status) |
| Log tails | `tail -n 100 <logfile>` (allowlist only) |

### Monitoring API Endpoints

```
GET /api/v1/monitoring/snapshot/   ← full system snapshot (JSON)
GET /api/v1/monitoring/cpu/
GET /api/v1/monitoring/memory/
GET /api/v1/monitoring/disk/?path=/
GET /api/v1/monitoring/uptime/
GET /api/v1/monitoring/services/
GET /api/v1/monitoring/network/
GET /api/v1/monitoring/logs/?log=django|nginx_access|nginx_error|gunicorn|install
```

All monitoring endpoints require **Admin JWT token** (`IsAdminUser` permission).

### Service Status Checked

| Service | systemctl name |
|---------|---------------|
| Django/Gunicorn | `ekafy` |
| Nginx | `nginx` |
| PostgreSQL | `postgresql` |
| Redis | `redis` |
| WordPress PHP | `php8.2-fpm` |

---

## 4. Product Management Module

### Model Fields

| Field | Type | Notes |
|-------|------|-------|
| `id` | BigAutoField | PK |
| `product_name` | CharField(255) | Required |
| `product_type` | CharField choices | software/hardware/service/digital/subscription |
| `status` | CharField choices | active/inactive/draft/archived |
| `description` | TextField | Optional |
| `created_at` | DateTimeField | auto_now_add |
| `updated_at` | DateTimeField | auto_now |

### API Endpoints

```
GET    /api/v1/products/              ← list (paginated, filterable)
POST   /api/v1/products/              ← create
GET    /api/v1/products/{id}/         ← detail
PUT    /api/v1/products/{id}/         ← full update
PATCH  /api/v1/products/{id}/         ← partial update
DELETE /api/v1/products/{id}/         ← admin only

POST   /api/v1/products/{id}/activate/    ← set status=active
POST   /api/v1/products/{id}/deactivate/  ← set status=inactive
GET    /api/v1/products/summary/           ← counts by status
```

### Query Parameters

```
?status=active           filter by status
?product_type=software   filter by type
?search=keyword          search name + description
?ordering=-created_at    ordering
?page=2                  pagination
```

### Initial Test Product

One real product is seeded via `load_initial.py`:
- **Name**: Ekafy Core API
- **Type**: software
- **Status**: active
- **Description**: Core REST API service for the Ekafy platform

---

## 5. Admin Dashboard

**URL**: `https://dashboard.ekafy.com/dashboard/`

### Access Control
- Requires Django session login (`is_staff=True`)
- Login page: `/dashboard/login/`
- All views protected by `@staff_required` decorator

### Dashboard Pages

| Page | URL | Features |
|------|-----|---------|
| Overview | `/dashboard/` | Live CPU/RAM/Disk/Uptime/Network + service health |
| Products | `/dashboard/products/` | Full product table |
| Services | `/dashboard/services/` | Start/stop/restart with AJAX |
| Logs | `/dashboard/logs/` | Color-coded log viewer, 100 lines |

### Live Refresh
- Dashboard metrics auto-refresh every **10 seconds** via `fetch('/dashboard/api/snapshot/')`
- Service statuses auto-refresh every **15 seconds**

### Service Control Security Model

```
User clicks "Restart nginx"
    ↓
POST /dashboard/api/service-control/  {service: "nginx", action: "restart"}
    ↓
service_control.py validates:
  service ∈ frozenset(['ekafy','nginx','postgresql','redis','php8.2-fpm'])
  action  ∈ frozenset(['restart','stop','start','status'])
    ↓
subprocess.run(['systemctl', 'restart', 'nginx'])  ← list form, NO shell=True
```

---

## 6. WordPress Setup

WordPress is **fully isolated** from Django:

```
/srv/ekafy/wordpress/     ← WordPress root
/srv/ekafy/logs/wp-credentials.txt  ← DB credentials (chmod 600)
```

### Database
- **Engine**: MariaDB (MySQL-compatible)
- **Database**: `ekafy_wp`
- **User**: `ekafy_wp`
- Completely separate from Django's PostgreSQL

### Security Hardening (Nginx)
- `wp-config.php` access blocked (`deny all`)
- `xmlrpc.php` blocked
- PHP execution limited to `.php` files only
- Hidden files/dirs blocked

### Post-Install Steps
1. Visit `http://blog.ekafy.com/wp-admin/install.php`
2. Complete WordPress site title and admin setup
3. Enable SSL via Certbot

---

## 7. Nginx Configuration

File: [nginx/ekafy.conf](file:///c:/Users/Ranga/Desktop/api-ekafy/api.ekafy/nginx/ekafy.conf)

### Key Features
- `upstream django_backend` with keepalive connection pooling
- Rate limiting: 60 req/min for API, 30 req/min for dashboard
- Security headers on all virtual hosts
- Static file serving with 30-day cache + `immutable`
- `nginx_status` restricted to `127.0.0.1` only
- WordPress PHP-FPM via Unix socket (faster than TCP)
- SSL-ready (certbot block is pre-written, just uncomment)

---

## 8. Systemd Services

File: [systemd/ekafy.service](file:///c:/Users/Ranga/Desktop/api-ekafy/api.ekafy/systemd/ekafy.service)

### Gunicorn Configuration
- **3 workers** (optimal for 2–4 GB VPS)
- `--max-requests 1000` + jitter (prevents memory leaks)
- `--timeout 30` (kills hung workers)
- Separate access + error log files

### Security Hardening
```ini
NoNewPrivileges=true    ← prevents privilege escalation
PrivateTmp=true         ← isolated /tmp
PrivateDevices=true     ← no device access
ProtectSystem=strict    ← read-only filesystem except ReadWritePaths
ProtectHome=true        ← no home directory access
```

---

## 9. Installer Script

File: [install.sh](file:///c:/Users/Ranga/Desktop/api-ekafy/api.ekafy/install.sh)

### Installation Steps
| Step | Action |
|------|--------|
| 1 | System update |
| 2 | Install: Python, Nginx, PostgreSQL, MariaDB, PHP 8.2, Redis |
| 3 | Create `ekafy` system user + sudoers rule |
| 4 | Create `/srv/ekafy/` directory structure |
| 5 | Git clone via SSH (generates key if missing) |
| 6 | Python venv + pip install requirements |
| 7 | Generate `.env` with cryptographically-random SECRET_KEY and DB_PASSWORD |
| 8 | PostgreSQL: create DB + user (idempotent) |
| 9 | Django: migrate + collectstatic + seed product |
| 10 | WordPress: download, configure wp-config.php, MariaDB setup |
| 11 | Systemd: install + enable `ekafy.service` + `php8.2-fpm` |
| 12 | Nginx: install config + reload |
| 13 | UFW: allow SSH (22), HTTP (80), HTTPS (443) |

### Idempotency
- Re-running the installer is safe — all steps check before acting
- Existing `.env`, `venv`, DB, WordPress install are preserved

---

## 10. Security Configuration

### Secrets
- All secrets in `/srv/ekafy/backend/.env` (chmod 600)
- SECRET_KEY: 50-char URL-safe random token
- DB passwords: cryptographically generated hex
- `.env` is git-ignored; `.env.example` is committed

### Network
- UFW firewall: only ports 22, 80, 443 open
- Django not exposed directly (Gunicorn binds to `127.0.0.1:8000` only)
- PHP-FPM via Unix socket (no TCP exposure)
- PostgreSQL on localhost only

### Application
- CSRF protection enabled on all POST forms
- Dashboard requires `is_staff=True`
- JWT for API authentication
- Service control uses strict allowlists (no shell injection possible)
- Log viewer uses path allowlist (no path traversal possible)
- Admin dashboard IP-restriction (optional, see Nginx config comment)

### WordPress
- `wp-config.php` blocked at Nginx level
- `xmlrpc.php` blocked
- Separate database and OS user from Django

---

## 11. Deployment Guide

### Prerequisites
- Fresh Ubuntu 22.04 or 24.04 VPS (2–4 GB RAM)
- Root SSH access
- Domains pointing to VPS IP (DNS A records)

### Step 1: Run Installer

```bash
curl -s https://install.ekafy.com | bash
# OR if cloned locally:
sudo bash install.sh
```

### Step 2: Create Django Superuser

```bash
cd /srv/ekafy/backend
source venv/bin/activate
python manage.py createsuperuser
```

### Step 3: Setup SSL

```bash
apt install certbot python3-certbot-nginx -y
certbot --nginx \
    -d api.ekafy.com \
    -d dashboard.ekafy.com \
    -d blog.ekafy.com \
    --email admin@ekafy.com \
    --agree-tos --non-interactive
```

### Step 4: Enable HTTPS redirect in .env

```bash
# Edit /srv/ekafy/backend/.env
FORCE_HTTPS=True
```

Then:
```bash
systemctl restart ekafy
```

### Step 5: Complete WordPress

Visit: `https://blog.ekafy.com/wp-admin/install.php`

### Step 6: Verify Everything

```bash
# Check service status
systemctl status ekafy nginx postgresql mariadb php8.2-fpm redis

# Test API
curl https://api.ekafy.com/api/v1/products/

# Check logs
journalctl -u ekafy -f
tail -f /srv/ekafy/logs/django.log
```

### Useful Commands

```bash
# Restart Django
systemctl restart ekafy

# View live logs
journalctl -u ekafy --follow

# Django shell
cd /srv/ekafy/backend && source venv/bin/activate && python manage.py shell

# PostgreSQL access
sudo -u postgres psql -d ekafy

# Nginx reload (zero-downtime)
nginx -t && systemctl reload nginx

# Re-run installer (safe)
sudo bash /srv/ekafy/backend/install.sh
```

---

## 12. API Reference

### Authentication

```bash
# Get JWT token
POST /api/v1/auth/token/
Content-Type: application/json
{"username": "admin", "password": "your-password"}

# Returns:
{"access": "<token>", "refresh": "<token>"}

# Use token:
Authorization: Bearer <access_token>
```

### Products

```bash
# List all products
GET /api/v1/products/
Authorization: Bearer <token>

# Create product
POST /api/v1/products/
{"product_name": "My SaaS", "product_type": "software", "status": "draft"}

# Activate product
POST /api/v1/products/1/activate/

# Summary
GET /api/v1/products/summary/
```

### Monitoring (Admin only)

```bash
# Full snapshot
GET /api/v1/monitoring/snapshot/

# Service statuses
GET /api/v1/monitoring/services/

# Logs
GET /api/v1/monitoring/logs/?log=django
```

---

> **Ekafy Hybrid Control System** · v2.0.0 · Production Ready  
> Designed for Ubuntu 22.04 / 24.04 · Django 4.2 · Nginx · PostgreSQL · WordPress
