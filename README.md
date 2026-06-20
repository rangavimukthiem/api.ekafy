# Ekafy Hybrid Control System

> Production-grade hybrid hosting platform — Django REST API · WordPress · Real-time Monitoring · Admin Dashboard

[![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-orange)](https://ubuntu.com)
[![Django](https://img.shields.io/badge/Django-4.2-green)](https://djangoproject.com)
[![License](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

## Quick Start

```bash
# One-command production install on fresh Ubuntu VPS
curl -s https://install.ekafy.com | bash
```

## Services

| URL | Service |
|-----|---------|
| `api.ekafy.com` | Django REST API (JWT auth, Products, Monitoring) |
| `dashboard.ekafy.com/dashboard/` | Admin dashboard (live metrics, service control) |
| `blog.ekafy.com` | WordPress CMS |

## Architecture

```
Internet → Nginx
             ├── api.ekafy.com       → Gunicorn :8000 (Django)
             ├── dashboard.ekafy.com → Gunicorn :8000 (Django)
             └── blog.ekafy.com      → PHP-FPM (WordPress)
```

## Stack

- **Backend**: Django 4.2, DRF, JWT, PostgreSQL, Redis, Gunicorn
- **CMS**: WordPress + MariaDB + PHP 8.2 FPM
- **Proxy**: Nginx with rate limiting + security headers
- **Monitoring**: Real /proc reads — CPU, RAM, Disk, Services
- **Security**: UFW, systemd hardening, .env secrets, staff-only dashboard

## Documentation

See [architecture.md](architecture.md) for full deployment guide.

## Project Structure

```
api.ekafy/
├── install.sh          ← production installer (v2.0)
├── nginx/ekafy.conf    ← multi-domain nginx config
├── systemd/ekafy.service
└── backend/            ← Django project
    ├── ekafy/          ← project settings
    ├── apps/
    │   ├── products/   ← product management module
    │   ├── monitoring/ ← real-time server metrics
    │   ├── dashboard/  ← HTML admin dashboard
    │   └── system_config/
    └── templates/dashboard/
```
