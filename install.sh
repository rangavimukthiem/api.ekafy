#!/usr/bin/env bash
echo "# =============================================================================
#
#   ███████╗██╗  ██╗ █████╗ ███████╗██╗   ██╗
#   ██╔════╝██║ ██╔╝██╔══██╗██╔════╝╚██╗ ██╔╝
#   █████╗  █████╔╝ ███████║█████╗   ╚████╔╝
#   ██╔══╝  ██╔═██╗ ██╔══██║██╔══╝    ╚██╔╝
#   ███████╗██║  ██╗██║  ██║██║        ██║
#   ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝        ╚═╝
#
#   EKAFY HYBRID CONTROL SYSTEM — INSTALLER v3.0
#   ─────────────────────────────────────────────
#   Supports  : Ubuntu 22.04 LTS / Ubuntu 24.04 LTS
#   Installs  : Django API · WordPress · Dashboard · Monitoring
#   Idempotent: Safe to re-run on existing installations
#   Log file  : /var/log/ekafy-install.log
#
#   USAGE:
#     bash install.sh                      (interactive)
#     bash install.sh --no-wp              (skip WordPress)
#     bash install.sh --no-redis           (skip Redis)
#     bash install.sh --check-only         (requirements check only)
#
#   REPLICATE TO NEW VPS:
#     scp install.sh root@NEW_VPS_IP:/root/
#     ssh root@NEW_VPS_IP "bash /root/install.sh"
#
# =============================================================================/n"

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
sleep 5

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — Edit these before running on each VPS
# ─────────────────────────────────────────────────────────────────────────────

EKAFY_VERSION="3.0.0"

# Domains (set to your actual domains or leave _ for localhost testing)
API_DOMAIN="${API_DOMAIN:-api.ekafy.com}"
BLOG_DOMAIN="${BLOG_DOMAIN:-blog.ekafy.com}"
DASH_DOMAIN="${DASH_DOMAIN:-dashboard.ekafy.com}"

# System user that runs Django/Gunicorn
EKAFY_USER="ekafy"
EKAFY_GROUP="www-data"

# Directory layout
EKAFY_BASE="/srv/ekafy"
BACKEND_DIR="${EKAFY_BASE}/backend"
WP_DIR="${EKAFY_BASE}/wordpress"
LOGS_DIR="${EKAFY_BASE}/logs"
LOGFILE="/var/log/ekafy-install.log"

# Service ports
GUNICORN_PORT="8000"
GUNICORN_WORKERS="3"          # Tune: (2 × CPU cores) + 1

# PHP version for WordPress
PHP_VERSION="8.2"

# GitHub repo (SSH) — change to your fork if needed
GITHUB_REPO="git@github.com:ekafy/core.git"
GITHUB_BRANCH="main"

# ─── Feature flags (override via CLI or environment) ──────────────────────────
INSTALL_WORDPRESS="${INSTALL_WORDPRESS:-yes}"
INSTALL_REDIS="${INSTALL_REDIS:-yes}"
SKIP_GIT_CLONE="${SKIP_GIT_CLONE:-no}"     # set 'yes' if code already at BACKEND_DIR
CHECK_ONLY="${CHECK_ONLY:-no}"

# Parse CLI flags
for arg in "$@"; do
    case "$arg" in
        --no-wp)       INSTALL_WORDPRESS="no" ;;
        --no-redis)    INSTALL_REDIS="no" ;;
        --no-clone)    SKIP_GIT_CLONE="yes" ;;
        --check-only)  CHECK_ONLY="yes" ;;
        --help|-h)
            echo "Usage: bash install.sh [--no-wp] [--no-redis] [--no-clone] [--check-only]"
            exit 0
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# COLORS & LOGGING
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# Setup log file
mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"
exec > >(tee -a "$LOGFILE") 2>&1

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_info()  { echo -e "${GREEN}  ✔${RESET} ${DIM}$(_ts)${RESET}  $*"; }
log_warn()  { echo -e "${YELLOW}  ⚠${RESET} ${DIM}$(_ts)${RESET}  $*"; }
log_error() { echo -e "${RED}  ✖${RESET} ${DIM}$(_ts)${RESET}  ${RED}$*${RESET}"; }
log_step()  { echo -e "\n${BLUE}${BOLD}  ══════════════════════════════════════${RESET}"; \
              echo -e "${BLUE}${BOLD}  $*${RESET}"; \
              echo -e "${BLUE}${BOLD}  ══════════════════════════════════════${RESET}"; }
log_check() { echo -e "${CYAN}  ▶${RESET} $*"; }
log_ok()    { echo -e "${GREEN}  ✔${RESET} ${GREEN}$*${RESET}"; }
log_fail()  { echo -e "${RED}  ✖${RESET} ${RED}$*${RESET}"; }
log_skip()  { echo -e "${DIM}  ─${RESET} ${DIM}$*${RESET}"; }

# ─────────────────────────────────────────────────────────────────────────────
# ERROR HANDLER
# ─────────────────────────────────────────────────────────────────────────────

INSTALL_FAILED=0

trap 'on_error $LINENO' ERR

on_error() {
    INSTALL_FAILED=1
    echo ""
    log_error "═══════════════════════════════════════════════"
    log_error "  INSTALLATION FAILED at line $1"
    log_error "  Check the full log: ${LOGFILE}"
    log_error "  Last 10 lines:"
    log_error "═══════════════════════════════════════════════"
    tail -n 10 "$LOGFILE" | while IFS= read -r line; do
        echo -e "    ${DIM}${line}${RESET}"
    done
    echo ""
    echo -e "  ${CYAN}Tip:${RESET} Fix the error above and re-run — the installer is idempotent."
    echo -e "  ${CYAN}Tip:${RESET} For verbose output: ${YELLOW}bash -x install.sh${RESET}"
    echo ""
    exit 1
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }
svc_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
svc_enabled(){ systemctl is-enabled --quiet "$1" 2>/dev/null; }
dir_exists() { [[ -d "$1" ]]; }
file_exists(){ [[ -f "$1" ]]; }
make_dir()   { [[ -d "$1" ]] || mkdir -p "$1"; }

# ─────────────────────────────────────────────────────────────────────────────
# BANNER
# ─────────────────────────────────────────────────────────────────────────────

print_banner() {
    echo ""
    echo -e "${BLUE}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║         EKAFY HYBRID CONTROL SYSTEM  v${EKAFY_VERSION}              ║"
    echo "  ║   Django API · WordPress · Dashboard · Real-time Monitoring  ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
    echo -e "  ${DIM}Log file : ${LOGFILE}${RESET}"
    echo -e "  ${DIM}Started  : $(_ts)${RESET}"
    echo ""

    echo -e "  ${BOLD}Configuration:${RESET}"
    echo -e "  ${DIM}API domain   :${RESET} ${CYAN}${API_DOMAIN}${RESET}"
    echo -e "  ${DIM}Blog domain  :${RESET} ${CYAN}${BLOG_DOMAIN}${RESET}"
    echo -e "  ${DIM}Dash domain  :${RESET} ${CYAN}${DASH_DOMAIN}${RESET}"
    echo -e "  ${DIM}Install WP   :${RESET} ${INSTALL_WORDPRESS}"
    echo -e "  ${DIM}Install Redis :${RESET} ${INSTALL_REDIS}"
    echo ""
}
echo " \n
# ============================================================================================
# ██████╗ ███████╗ ██████╗ ██╗   ██╗██╗██████╗ ███████╗███╗   ███╗███████╗███╗   ██╗████████╗███████╗
# ██╔══██╗██╔════╝██╔═══██╗██║   ██║██║██╔══██╗██╔════╝████╗ ████║██╔════╝████╗  ██║╚══██╔══╝██╔════╝
# ██████╔╝█████╗  ██║   ██║██║   ██║██║██████╔╝█████╗  ██╔████╔██║█████╗  ██╔██╗ ██║   ██║   ███████╗
# ██╔══██╗██╔══╝  ██║▄▄ ██║██║   ██║██║██╔══██╗██╔══╝  ██║╚██╔╝██║██╔══╝  ██║╚██╗██║   ██║   ╚════██║
# ██║  ██║███████╗╚██████╔╝╚██████╔╝██║██║  ██║███████╗██║ ╚═╝ ██║███████╗██║ ╚████║   ██║   ███████║
# ╚═╝  ╚═╝╚══════╝ ╚══▀▀═╝  ╚═════╝ ╚═╝╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝╚══════╝╚═╝  ╚═══╝   ╚═╝   ╚══════╝
# ============================================================================================
# PRE-FLIGHT REQUIREMENTS CHECK
# Runs BEFORE any installation. Reports all issues at once so you can fix
# everything before re-running.
# ============================================================================================\n "

# Tracking
REQ_PASS=0
REQ_FAIL=0
REQ_WARN=0

req_ok()   { log_ok   "  $1"; ((REQ_PASS++)) || true; }
req_fail() { log_fail "  $1"; ((REQ_FAIL++)) || true; }
req_warn() { log_warn "  $1"; ((REQ_WARN++)) || true; }

check_requirements() {
    log_step "PRE-FLIGHT REQUIREMENTS CHECK"
    echo ""

    # ── 1. Root access ────────────────────────────────────────────────────────
    echo -e "  ${BOLD}[1] Root / sudo access${RESET}"
    if [[ "${EUID}" -eq 0 ]]; then
        req_ok "Running as root"
    else
        req_fail "Must run as root: sudo bash install.sh"
    fi
    echo ""

    # ── 2. Operating system ───────────────────────────────────────────────────
    echo -e "  ${BOLD}[2] Operating System${RESET}"
    if file_exists /etc/os-release; then
        local os_name os_version
        os_name=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"')
        os_version=$(grep -oP '(?<=^VERSION_ID=).+' /etc/os-release | tr -d '"')

        if [[ "${os_name}" == "ubuntu" ]]; then
            if [[ "${os_version}" == "22.04" || "${os_version}" == "24.04" ]]; then
                req_ok "Ubuntu ${os_version} LTS — fully supported"
            else
                req_warn "Ubuntu ${os_version} — untested, may work"
            fi
        else
            req_fail "Detected: ${os_name} ${os_version} — only Ubuntu 22.04/24.04 supported"
        fi
    else
        req_fail "Cannot detect OS — /etc/os-release missing"
    fi
    echo ""

    # ── 3. Hardware resources ─────────────────────────────────────────────────
    echo -e "  ${BOLD}[3] Hardware Resources${RESET}"

    local ram_kb ram_mb cpu_cores disk_free_gb
    ram_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
    ram_mb=$((ram_kb / 1024))
    cpu_cores=$(nproc 2>/dev/null || echo 1)
    disk_free_gb=$(df -BG / 2>/dev/null | awk 'NR==2 {gsub("G",""); print $4}' || echo 0)

    if [[ "${ram_mb}" -ge 1800 ]]; then
        req_ok "RAM: ${ram_mb} MB (minimum 2 GB recommended ✔)"
    elif [[ "${ram_mb}" -ge 900 ]]; then
        req_warn "RAM: ${ram_mb} MB — tight, reduce Gunicorn workers to 2"
    else
        req_fail "RAM: ${ram_mb} MB — too low, minimum 1 GB required"
    fi

    if [[ "${disk_free_gb}" -ge 10 ]]; then
        req_ok "Free disk: ${disk_free_gb} GB (minimum 10 GB ✔)"
    elif [[ "${disk_free_gb}" -ge 5 ]]; then
        req_warn "Free disk: ${disk_free_gb} GB — low, WordPress may fill this quickly"
    else
        req_fail "Free disk: ${disk_free_gb} GB — minimum 5 GB required"
    fi

    req_ok "CPU cores: ${cpu_cores} (recommended workers = $((cpu_cores * 2 + 1)))"
    echo ""

    # ── 4. Internet connectivity ──────────────────────────────────────────────
    echo -e "  ${BOLD}[4] Internet Connectivity${RESET}"

    local targets=("8.8.8.8" "1.1.1.1")
    local net_ok=0
    for ip in "${targets[@]}"; do
        if ping -c 1 -W 3 "${ip}" &>/dev/null 2>&1; then
            net_ok=1; break
        fi
    done

    if [[ "${net_ok}" -eq 1 ]]; then
        req_ok "Network: internet reachable"
    else
        req_fail "Network: no internet — cannot install packages"
    fi

    # DNS
    if host github.com &>/dev/null 2>&1 || nslookup github.com &>/dev/null 2>&1; then
        req_ok "DNS: resolving github.com ✔"
    else
        req_warn "DNS: cannot resolve github.com — check /etc/resolv.conf"
    fi

    # GitHub HTTPS reachable
    if curl -s --max-time 8 --head https://api.github.com -o /dev/null 2>/dev/null; then
        req_ok "GitHub API: reachable ✔"
    else
        req_warn "GitHub: unreachable over HTTPS — SSH clone may still work"
    fi

    # Ubuntu package servers
    if curl -s --max-time 8 --head https://archive.ubuntu.com -o /dev/null 2>/dev/null; then
        req_ok "Ubuntu apt mirror: reachable ✔"
    else
        req_warn "Ubuntu apt mirror: slow or unreachable — install may take longer"
    fi
    echo ""

    # ── 5. SSH Key for GitHub ─────────────────────────────────────────────────
    echo -e "  ${BOLD}[5] SSH Key (for GitHub clone)${RESET}"
    if [[ "${SKIP_GIT_CLONE}" == "yes" ]]; then
        req_ok "Git clone skipped (--no-clone flag set)"
    else
        local ssh_key_found=0
        for key in ~/.ssh/id_ed25519 ~/.ssh/id_rsa ~/.ssh/id_ecdsa ~/.ssh/id_ecdsa_sk; do
            if [[ -f "${key}" ]]; then
                req_ok "SSH private key found: ${key}"
                ssh_key_found=1
                break
            fi
        done
        if [[ "${ssh_key_found}" -eq 0 ]]; then
            req_warn "No SSH key found — installer will auto-generate one"
            req_warn "You'll need to add the public key to GitHub before clone"
        fi

        # known_hosts
        if grep -q "github.com" ~/.ssh/known_hosts 2>/dev/null; then
            req_ok "GitHub in SSH known_hosts ✔"
        else
            req_warn "GitHub not in known_hosts — will be added automatically"
        fi
    fi
    echo ""

    # ── 6. Required commands ──────────────────────────────────────────────────
    echo -e "  ${BOLD}[6] Pre-installed Commands${RESET}"
    local required_cmds=(curl wget apt-get systemctl)
    for c in "${required_cmds[@]}"; do
        if cmd_exists "${c}"; then
            req_ok "${c} found at $(command -v "${c}")"
        else
            req_fail "${c} not found — cannot proceed"
        fi
    done
    echo ""

    # ── 7. Ports availability ─────────────────────────────────────────────────
    echo -e "  ${BOLD}[7] Port Availability${RESET}"
    local ports=(80 443 5432 3306 6379 8000)
    for port in "${ports[@]}"; do
        if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
           netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
            req_warn "Port ${port} already in use — may conflict"
        else
            req_ok "Port ${port} is free"
        fi
    done
    echo ""

    # ── 8. Existing installation check ───────────────────────────────────────
    echo -e "  ${BOLD}[8] Existing Installation${RESET}"
    if dir_exists "${EKAFY_BASE}"; then
        req_warn "${EKAFY_BASE}/ already exists — running in UPDATE mode (safe)"
    else
        req_ok "Fresh installation — no conflicts"
    fi

    if cmd_exists nginx; then
        req_warn "Nginx already installed ($(nginx -v 2>&1 | head -1)) — config will be updated"
    else
        req_ok "Nginx: not yet installed — will be installed"
    fi

    if cmd_exists python3; then
        req_ok "Python3: $(python3 --version) found"
    else
        req_ok "Python3: not yet installed — will be installed"
    fi

    if cmd_exists psql; then
        req_warn "PostgreSQL: $(psql --version) already installed — DB will be configured if needed"
    else
        req_ok "PostgreSQL: not yet installed — will be installed"
    fi

    if [[ "${INSTALL_WORDPRESS}" == "yes" ]]; then
        if cmd_exists mysql || cmd_exists mariadb; then
            req_warn "MariaDB/MySQL already installed — WordPress DB will be created if needed"
        else
            req_ok "MariaDB: not yet installed — will be installed for WordPress"
        fi
    fi

    if [[ "${INSTALL_REDIS}" == "yes" ]]; then
        if cmd_exists redis-cli; then
            req_warn "Redis: $(redis-cli --version) already installed"
        else
            req_ok "Redis: not yet installed — will be installed"
        fi
    fi
    echo ""

    # ── 9. Firewall status ────────────────────────────────────────────────────
    echo -e "  ${BOLD}[9] Firewall Status${RESET}"
    if cmd_exists ufw; then
        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | head -1 || echo "unknown")
        if echo "${ufw_status}" | grep -qi "active"; then
            local ssh_allowed
            ssh_allowed=$(ufw status 2>/dev/null | grep -c "22/tcp\|OpenSSH\|22 " || true)
            if [[ "${ssh_allowed}" -gt 0 ]]; then
                req_ok "UFW active, SSH port 22 already allowed ✔"
            else
                req_warn "UFW active but SSH may not be allowed — installer will add SSH rule first"
            fi
        else
            req_ok "UFW inactive — installer will enable it safely (SSH first)"
        fi
    else
        req_ok "UFW not installed — will be installed and configured"
    fi
    echo ""

    # ── REQUIREMENTS SUMMARY ─────────────────────────────────────────────────
    echo -e "  ${BOLD}══════════════════════════════════════════${RESET}"
    echo -e "  ${BOLD}REQUIREMENTS CHECK SUMMARY${RESET}"
    echo -e "  ${GREEN}  ✔ Passed : ${REQ_PASS}${RESET}"
    echo -e "  ${YELLOW}  ⚠ Warnings: ${REQ_WARN}${RESET} (installation will proceed)"
    echo -e "  ${RED}  ✖ Failed : ${REQ_FAIL}${RESET}"
    echo -e "  ${BOLD}══════════════════════════════════════════${RESET}"
    echo ""

    if [[ "${REQ_FAIL}" -gt 0 ]]; then
        log_error "Requirements check failed. Fix the ${RED}✖ FAILED${RESET} items above, then re-run."
        exit 1
    fi

    if [[ "${CHECK_ONLY}" == "yes" ]]; then
        log_info "Requirements check complete (--check-only mode). No installation performed."
        exit 0
    fi

    if [[ "${REQ_WARN}" -gt 0 ]]; then
        echo -e "  ${YELLOW}${BOLD}Warnings found. Review them above.${RESET}"
        read -rp "  Continue with installation? [Y/n]: " confirm
        confirm="${confirm:-Y}"
        if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
            echo "  Installation cancelled."
            exit 0
        fi
    fi

    echo ""
}

# =============================================================================
# INSTALLATION STEPS
# =============================================================================

# ─── STEP 1: System Update ───────────────────────────────────────────────────
step_01_system_update() {
    log_step "STEP 1/12 — System Update"
    apt-get update -qq
    apt-get upgrade -y -qq --no-install-recommends
    apt-get install -y -qq apt-transport-https ca-certificates lsb-release
    log_info "System packages updated."
}

# ─── STEP 2: Install Dependencies ────────────────────────────────────────────
step_02_dependencies() {
    log_step "STEP 2/12 — Installing Dependencies"

    echo -e "  ${DIM}Installing: Python 3, build tools, Nginx, PostgreSQL...${RESET}"
    apt-get install -y -qq \
        python3 python3-pip python3-venv python3-dev \
        build-essential libpq-dev libssl-dev libffi-dev \
        git curl wget unzip gnupg2 \
        software-properties-common \
        ufw \
        nginx

    log_info "Python3, Git, Nginx, build tools installed."

    echo -e "  ${DIM}Installing: PostgreSQL...${RESET}"
    apt-get install -y -qq postgresql postgresql-contrib
    log_info "PostgreSQL installed."

    if [[ "${INSTALL_REDIS}" == "yes" ]]; then
        echo -e "  ${DIM}Installing: Redis...${RESET}"
        apt-get install -y -qq redis-server
        systemctl enable redis-server --quiet
        systemctl start redis-server
        log_info "Redis installed and started."
    else
        log_skip "Redis skipped (--no-redis)"
    fi

    if [[ "${INSTALL_WORDPRESS}" == "yes" ]]; then
        echo -e "  ${DIM}Installing: MariaDB for WordPress...${RESET}"
        apt-get install -y -qq mariadb-server mariadb-client
        log_info "MariaDB installed."

        echo -e "  ${DIM}Installing: PHP ${PHP_VERSION} + FPM for WordPress...${RESET}"
        
        echo -e "  ${DIM}Installing: PHP ${PHP_VERSION} + FPM for WordPress...${RESET}"

# Ensure PPA is properly added (do NOT hide errors)
if ! grep -R "ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d >/dev/null 2>&1; then
    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
fi

apt-get update -qq

# Detect best available PHP version if 8.2 not available
if apt-cache show "php${PHP_VERSION}" >/dev/null 2>&1; then
    PHP_REAL_VERSION="${PHP_VERSION}"
else
    log_warn "PHP ${PHP_VERSION} not available — falling back to default PHP version"
    PHP_REAL_VERSION=$(apt-cache search "^php[0-9].[0-9]-fpm$" | awk '{print $1}' | head -n 1 | sed 's/php//;s/-fpm//')
fi

log_info "Using PHP version: ${PHP_REAL_VERSION}"

apt-get install -y -qq \
    "php${PHP_REAL_VERSION}" "php${PHP_REAL_VERSION}-fpm" \
    "php${PHP_REAL_VERSION}-mysql" "php${PHP_REAL_VERSION}-curl" \
    "php${PHP_REAL_VERSION}-gd" "php${PHP_REAL_VERSION}-mbstring" \
    "php${PHP_REAL_VERSION}-xml" "php${PHP_REAL_VERSION}-zip" \
    "php${PHP_REAL_VERSION}-intl" "php${PHP_REAL_VERSION}-bcmath" \
    "php${PHP_REAL_VERSION}-imagick"

    else
        log_skip "WordPress/MariaDB/PHP skipped (--no-wp)"
    fi

    log_info "All dependencies installed."
}

# ─── STEP 3: System User ─────────────────────────────────────────────────────
step_03_user() {
    log_step "STEP 3/12 — System User"

    if id -u "${EKAFY_USER}" &>/dev/null; then
        log_info "User '${EKAFY_USER}' already exists — skipping."
    else
        useradd \
            --system \
            --no-create-home \
            --shell /usr/sbin/nologin \
            --gid "${EKAFY_GROUP}" \
            "${EKAFY_USER}"
        log_info "System user '${EKAFY_USER}' created (no login shell)."
    fi

    # Sudoers rule for safe service control from Django dashboard
    local sudoers_f="/etc/sudoers.d/99-ekafy-services"
    cat > "${sudoers_f}" <<SUDOERS
# Ekafy dashboard — safe systemctl access (no-password, allowlist only)
${EKAFY_USER} ALL=(root) NOPASSWD: /bin/systemctl restart ekafy
${EKAFY_USER} ALL=(root) NOPASSWD: /bin/systemctl start ekafy
${EKAFY_USER} ALL=(root) NOPASSWD: /bin/systemctl stop ekafy
${EKAFY_USER} ALL=(root) NOPASSWD: /bin/systemctl restart nginx
${EKAFY_USER} ALL=(root) NOPASSWD: /bin/systemctl reload nginx
${EKAFY_USER} ALL=(root) NOPASSWD: /bin/systemctl restart postgresql
${EKAFY_USER} ALL=(root) NOPASSWD: /bin/systemctl restart redis
${EKAFY_USER} ALL=(root) NOPASSWD: /bin/systemctl restart redis-server
${EKAFY_USER} ALL=(root) NOPASSWD: /bin/systemctl restart php${PHP_VERSION}-fpm
SUDOERS
    chmod 440 "${sudoers_f}"

    if visudo -cf "${sudoers_f}" &>/dev/null; then
        log_info "Sudoers rule installed and validated."
    else
        log_warn "Sudoers validation failed — removing. Service control from dashboard will need manual setup."
        rm -f "${sudoers_f}"
    fi
}

# ─── STEP 4: Directories ─────────────────────────────────────────────────────
step_04_directories() {
    log_step "STEP 4/12 — Directory Structure"

    make_dir "${EKAFY_BASE}"
    make_dir "${BACKEND_DIR}"
    make_dir "${LOGS_DIR}"
    [[ "${INSTALL_WORDPRESS}" == "yes" ]] && make_dir "${WP_DIR}"

    # Set ownership
    chown -R "${EKAFY_USER}:${EKAFY_GROUP}" "${EKAFY_BASE}"
    chmod -R 755 "${EKAFY_BASE}"
    chmod 775 "${LOGS_DIR}"

    log_info "Directory structure ready:"
    log_info "  ${EKAFY_BASE}/"
    log_info "  ├── backend/   (Django)"
    log_info "  ├── wordpress/ (WordPress)"
    log_info "  └── logs/      (Application logs)"
}

# ─── STEP 5: SSH Key + Git Clone ─────────────────────────────────────────────
step_05_git_clone() {
    log_step "STEP 5/12 — Git Clone (SSH)"

    if [[ "${SKIP_GIT_CLONE}" == "yes" ]]; then
        log_skip "Git clone skipped (--no-clone). Expecting code at ${BACKEND_DIR}"
        return
    fi

    # ─────────────────────────────────────────────
    # DETECT REAL USER (CRITICAL FOR sudo SAFETY)
    # ─────────────────────────────────────────────

    DEPLOY_USER="${SUDO_USER:-$USER}"
    DEPLOY_HOME="$(eval echo "~${DEPLOY_USER}")"

    SSH_DIR="${DEPLOY_HOME}/.ssh"
    SSH_KEY="${SSH_DIR}/id_ed25519"

    mkdir -p "${SSH_DIR}"
    chmod 700 "${SSH_DIR}"

    log_info "Using SSH key for user: ${DEPLOY_USER}"

    # ─────────────────────────────────────────────
    # CREATE KEY IF MISSING
    # ─────────────────────────────────────────────

    if [[ ! -f "${SSH_KEY}" ]]; then
        log_warn "No SSH key found — generating..."

        sudo -u "${DEPLOY_USER}" ssh-keygen -t ed25519 \
            -C "ekafy-deploy@$(hostname)" \
            -f "${SSH_KEY}" \
            -N ""

        echo ""
        echo "════════════════════════════════════"
        echo " ADD THIS KEY TO GITHUB"
        echo "════════════════════════════════════"
        echo ""

        cat "${SSH_KEY}.pub"

        echo ""
        read -rp "Press ENTER after adding key to GitHub..."
    fi

    chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${SSH_DIR}"

    # ─────────────────────────────────────────────
    # SSH AGENT FIX (VERY IMPORTANT)
    # ─────────────────────────────────────────────

    sudo -u "${DEPLOY_USER}" bash -c "
        eval \$(ssh-agent -s) >/dev/null
        ssh-add ${SSH_KEY} 2>/dev/null || true
    "

    # ─────────────────────────────────────────────
    # known_hosts
    # ─────────────────────────────────────────────

    touch "${SSH_DIR}/known_hosts"
    ssh-keyscan -H github.com >> "${SSH_DIR}/known_hosts" 2>/dev/null

    # ─────────────────────────────────────────────
    # TEST SSH BEFORE CLONE (NO FALSE POSITIVES)
    # ─────────────────────────────────────────────

    log_check "Testing GitHub SSH access..."

    SSH_TEST=$(
        sudo -u "${DEPLOY_USER}" ssh -o BatchMode=yes -T git@github.com 2>&1 || true
    )

    if ! echo "$SSH_TEST" | grep -qi "successfully authenticated"; then
        log_error "GitHub SSH authentication FAILED"
        echo "$SSH_TEST"
        exit 1
    fi

    log_info "GitHub SSH authentication OK"

    # ─────────────────────────────────────────────
    # CLONE / UPDATE
    # ─────────────────────────────────────────────

    if [[ -d "${BACKEND_DIR}/.git" ]]; then

        log_info "Updating repository..."

        git -C "${BACKEND_DIR}" fetch origin
        git -C "${BACKEND_DIR}" reset --hard "origin/${GITHUB_BRANCH}"

    else

        log_info "Cloning repository..."

        sudo -u "${DEPLOY_USER}" git clone \
            --depth 1 \
            --branch "${GITHUB_BRANCH}" \
            "${GITHUB_REPO}" \
            "${BACKEND_DIR}"
    fi

    # ─────────────────────────────────────────────
    # FIX PERMISSIONS SAFELY (NO HARD-CODED GROUPS)
    # ─────────────────────────────────────────────

    chown -R "${DEPLOY_USER}" "${BACKEND_DIR}"

    log_info "Backend ready at ${BACKEND_DIR}"
}

# ─── STEP 6: Python Virtual Environment ──────────────────────────────────────
step_06_python_env() {
    log_step "STEP 6/12 — Python Virtual Environment"

    if [[ ! -d "${BACKEND_DIR}/venv" ]]; then
        python3 -m venv "${BACKEND_DIR}/venv"
        log_info "Virtual environment created."
    else
        log_info "Virtual environment already exists — upgrading pip only."
    fi

    local PIP="${BACKEND_DIR}/venv/bin/pip"
    local PYTHON="${BACKEND_DIR}/venv/bin/python"

    "${PIP}" install --upgrade pip --quiet

    if file_exists "${BACKEND_DIR}/requirements.txt"; then
        log_info "Installing pip requirements..."
        "${PIP}" install -r "${BACKEND_DIR}/requirements.txt" --quiet
        log_info "Requirements installed."
    else
        log_warn "requirements.txt not found — installing minimal set..."
        "${PIP}" install --quiet \
            "django>=4.2,<5.0" \
            "djangorestframework>=3.15" \
            "djangorestframework-simplejwt>=5.3" \
            "django-cors-headers>=4.3" \
            "django-filter>=23.5" \
            "psycopg2-binary>=2.9" \
            "gunicorn>=21.2" \
            "whitenoise>=6.6"
        [[ "${INSTALL_REDIS}" == "yes" ]] && "${PIP}" install --quiet "redis>=5.0"
    fi

    # Always ensure gunicorn
    "${PIP}" install gunicorn --quiet

    chown -R "${EKAFY_USER}:${EKAFY_GROUP}" "${BACKEND_DIR}/venv"

    log_info "Python env ready — $(${PYTHON} --version)"
    log_info "Gunicorn ready — $("${BACKEND_DIR}/venv/bin/gunicorn" --version)"
}

# ─── STEP 7: Environment File ─────────────────────────────────────────────────
step_07_env_file() {
    log_step "STEP 7/12 — Environment Configuration"

    local env_file="${BACKEND_DIR}/.env"

    if file_exists "${env_file}"; then
        log_info ".env already exists — NOT overwriting (secrets preserved)."
        log_info "To regenerate: rm ${env_file} && bash install.sh"
        return
    fi

    # Generate cryptographically-random secrets
    local secret_key db_pass
    secret_key=$(python3 -c "import secrets; print(secrets.token_urlsafe(50))")
    db_pass=$(python3 -c "import secrets; print(secrets.token_hex(16))")

    cat > "${env_file}" <<ENV
# ═══════════════════════════════════════════════════════
# EKAFY Environment — Generated by installer v${EKAFY_VERSION}
# Date: $(_ts)
# Host: $(hostname -f 2>/dev/null || hostname)
# ═══════════════════════════════════════════════════════

# ── Django Core ──────────────────────────────────────
DEBUG=False
SECRET_KEY=${secret_key}
ALLOWED_HOSTS=${API_DOMAIN},${DASH_DOMAIN},127.0.0.1,localhost

# ── Database (PostgreSQL) ────────────────────────────
DB_NAME=ekafy
DB_USER=ekafy
DB_PASSWORD=${db_pass}
DB_HOST=localhost
DB_PORT=5432

# ── Cache ────────────────────────────────────────────
REDIS_URL=redis://127.0.0.1:6379/1

# ── JWT ──────────────────────────────────────────────
JWT_ACCESS_MINUTES=60
JWT_REFRESH_DAYS=7

# ── CORS ─────────────────────────────────────────────
CORS_ALLOWED_ORIGINS=https://${DASH_DOMAIN}

# ── Misc ─────────────────────────────────────────────
TIME_ZONE=UTC
LOG_LEVEL=INFO
LOG_FILE=${LOGS_DIR}/django.log
FORCE_HTTPS=False
MONITORING_LOG_LINES=100
ENV

    chown "${EKAFY_USER}:${EKAFY_GROUP}" "${env_file}"
    chmod 600 "${env_file}"

    log_info ".env created with auto-generated secrets."
    log_warn "IMPORTANT: Backup ${env_file} — you'll need it to restore the system!"
}

# ─── STEP 8: PostgreSQL Setup ─────────────────────────────────────────────────
step_08_postgresql() {
    log_step "STEP 8/12 — PostgreSQL Setup"

    systemctl enable postgresql --quiet
    systemctl start postgresql

    # Read credentials from .env
    local db_name db_user db_pass
    db_name=$(grep '^DB_NAME='     "${BACKEND_DIR}/.env" | cut -d= -f2-)
    db_user=$(grep '^DB_USER='     "${BACKEND_DIR}/.env" | cut -d= -f2-)
    db_pass=$(grep '^DB_PASSWORD=' "${BACKEND_DIR}/.env" | cut -d= -f2-)

    # Create role (idempotent)
    if ! sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${db_user}'" 2>/dev/null | grep -q 1; then
        sudo -u postgres psql -c "CREATE USER ${db_user} WITH PASSWORD '${db_pass}';" 2>/dev/null
        sudo -u postgres psql -c "ALTER ROLE ${db_user} SET client_encoding TO 'utf8';" 2>/dev/null
        sudo -u postgres psql -c "ALTER ROLE ${db_user} SET default_transaction_isolation TO 'read committed';" 2>/dev/null
        sudo -u postgres psql -c "ALTER ROLE ${db_user} SET timezone TO 'UTC';" 2>/dev/null
        log_info "PostgreSQL user '${db_user}' created."
    else
        # Update password on re-run (in case .env was regenerated)
        sudo -u postgres psql -c "ALTER USER ${db_user} WITH PASSWORD '${db_pass}';" 2>/dev/null || true
        log_info "PostgreSQL user '${db_user}' already exists — password synced."
    fi

    # Create database (idempotent)
    if ! sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${db_name}'" 2>/dev/null | grep -q 1; then
        sudo -u postgres psql -c "CREATE DATABASE ${db_name} OWNER ${db_user};" 2>/dev/null
        log_info "PostgreSQL database '${db_name}' created."
    else
        log_info "PostgreSQL database '${db_name}' already exists."
    fi

    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${db_name} TO ${db_user};" 2>/dev/null || true

    log_info "PostgreSQL ready."
}

# ─── STEP 9: Django Setup ────────────────────────────────────────────────────
step_09_django() {
    log_step "STEP 9/12 — Django Setup"

    local PYTHON="${BACKEND_DIR}/venv/bin/python"
    local MANAGE="${BACKEND_DIR}/manage.py"

    if [[ ! -f "${MANAGE}" ]]; then
        log_warn "manage.py not found — skipping Django setup. Deploy your code first."
        return
    fi

    # Source .env for migrations
    set -a; source "${BACKEND_DIR}/.env"; set +a

    log_info "Running migrations..."
    "${PYTHON}" "${MANAGE}" migrate --noinput

    log_info "Collecting static files..."
    "${PYTHON}" "${MANAGE}" collectstatic --noinput --clear 2>/dev/null || \
    "${PYTHON}" "${MANAGE}" collectstatic --noinput

    # Seed initial product (idempotent)
    local seed_script="${BACKEND_DIR}/apps/products/fixtures/load_initial.py"
    if file_exists "${seed_script}"; then
        log_info "Seeding initial product data..."
        "${PYTHON}" "${MANAGE}" shell < "${seed_script}"
    fi

    chown -R "${EKAFY_USER}:${EKAFY_GROUP}" "${BACKEND_DIR}"
    log_info "Django migrations + static files done."
}

# ─── STEP 10: WordPress Setup ─────────────────────────────────────────────────
step_10_wordpress() {
    if [[ "${INSTALL_WORDPRESS}" != "yes" ]]; then
        log_skip "STEP 10/12 — WordPress (skipped via --no-wp)"
        return
    fi

    log_step "STEP 10/12 — WordPress + MariaDB Setup"

    # MariaDB
    systemctl enable mariadb --quiet
    systemctl start mariadb

    local wp_db_name="ekafy_wp"
    local wp_db_user="ekafy_wp"
    local wp_creds_file="${LOGS_DIR}/wp-credentials.txt"

    # Generate or read existing WP DB password
    local wp_db_pass
    if file_exists "${wp_creds_file}"; then
        wp_db_pass=$(grep 'DB_PASSWORD' "${wp_creds_file}" 2>/dev/null | tail -1 | cut -d= -f2 || true)
    fi
    if [[ -z "${wp_db_pass:-}" ]]; then
        wp_db_pass=$(python3 -c "import secrets; print(secrets.token_hex(12))")
    fi

    # Create DB + user (idempotent)
    mysql -e "CREATE DATABASE IF NOT EXISTS \`${wp_db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || true
    mysql -e "CREATE USER IF NOT EXISTS '${wp_db_user}'@'localhost' IDENTIFIED BY '${wp_db_pass}';" 2>/dev/null || true
    mysql -e "GRANT ALL PRIVILEGES ON \`${wp_db_name}\`.* TO '${wp_db_user}'@'localhost';" 2>/dev/null || true
    mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    log_info "MariaDB database '${wp_db_name}' ready."

    # Download WordPress (if not already installed)
    if [[ ! -f "${WP_DIR}/wp-login.php" ]]; then
        log_info "Downloading WordPress latest..."
        wget -qO /tmp/wordpress.tar.gz https://wordpress.org/latest.tar.gz
        tar -xzf /tmp/wordpress.tar.gz -C /tmp/
        rsync -a --delete /tmp/wordpress/ "${WP_DIR}/"
        rm -f /tmp/wordpress.tar.gz
        rm -rf /tmp/wordpress/
        log_info "WordPress extracted to ${WP_DIR}/"

        # Configure wp-config.php
        cp "${WP_DIR}/wp-config-sample.php" "${WP_DIR}/wp-config.php"
        sed -i "s/database_name_here/${wp_db_name}/g" "${WP_DIR}/wp-config.php"
        sed -i "s/username_here/${wp_db_user}/g"      "${WP_DIR}/wp-config.php"
        sed -i "s/password_here/${wp_db_pass}/g"      "${WP_DIR}/wp-config.php"
        log_info "wp-config.php configured."

        # Inject WordPress security salts
        local wp_salts
        wp_salts=$(curl -s --max-time 10 https://api.wordpress.org/secret-key/1.1/salt/ || true)
        if [[ -n "${wp_salts}" ]]; then
            python3 - <<PYEOF
config_path = "${WP_DIR}/wp-config.php"
with open(config_path, 'r') as f:
    content = f.read()
marker_start = "define( 'AUTH_KEY'"
marker_end   = "define( 'NONCE_SALT'"
s = content.find(marker_start)
e = content.find(marker_end)
if s != -1 and e != -1:
    e = content.find(";", e) + 1
    new_salts = """${wp_salts}"""
    content = content[:s] + new_salts + "\n" + content[e:]
    with open(config_path, 'w') as f:
        f.write(content)
    print("WordPress salts injected.")
else:
    print("Warning: salt markers not found in wp-config.php.")
PYEOF
        else
            log_warn "Could not fetch WordPress salts — edit wp-config.php manually."
        fi
    else
        log_info "WordPress already installed at ${WP_DIR}/ — skipping download."
    fi

    # Set permissions
    chown -R "${EKAFY_USER}:${EKAFY_GROUP}" "${WP_DIR}"
    find "${WP_DIR}" -type d -exec chmod 755 {} \;
    find "${WP_DIR}" -type f -exec chmod 644 {} \;
    chmod 600 "${WP_DIR}/wp-config.php"

    # Enable PHP-FPM
    systemctl enable "php${PHP_VERSION}-fpm" --quiet
    systemctl restart "php${PHP_VERSION}-fpm"
    log_info "php${PHP_VERSION}-fpm started."

    # Save credentials file (mode 600)
    {
        echo "# WordPress DB Credentials — $(_ts)"
        echo "DB_NAME=${wp_db_name}"
        echo "DB_USER=${wp_db_user}"
        echo "DB_PASSWORD=${wp_db_pass}"
        echo "DB_HOST=localhost"
        echo "Setup URL=http://${BLOG_DOMAIN}/wp-admin/install.php"
    } > "${wp_creds_file}"
    chmod 600 "${wp_creds_file}"
    chown root:root "${wp_creds_file}"

    log_info "WordPress credentials saved to ${wp_creds_file}"
    log_warn "Complete setup at: http://${BLOG_DOMAIN}/wp-admin/install.php"
}

# ─── STEP 11: Systemd Service ─────────────────────────────────────────────────
step_11_systemd() {
    log_step "STEP 11/12 — Systemd Service (Gunicorn)"

    cat > /etc/systemd/system/ekafy.service <<SERVICE
[Unit]
Description=Ekafy Django API + Dashboard (Gunicorn)
Documentation=https://github.com/ekafy/core
After=network.target postgresql.service
Wants=postgresql.service

[Service]
User=${EKAFY_USER}
Group=${EKAFY_GROUP}
WorkingDirectory=${BACKEND_DIR}
EnvironmentFile=${BACKEND_DIR}/.env

ExecStart=${BACKEND_DIR}/venv/bin/gunicorn \\
    ekafy.wsgi:application \\
    --bind 127.0.0.1:${GUNICORN_PORT} \\
    --workers ${GUNICORN_WORKERS} \\
    --worker-class sync \\
    --max-requests 1000 \\
    --max-requests-jitter 100 \\
    --timeout 30 \\
    --keep-alive 5 \\
    --access-logfile ${LOGS_DIR}/gunicorn.log \\
    --error-logfile ${LOGS_DIR}/gunicorn-error.log \\
    --log-level warning \\
    --capture-output

ExecReload=/bin/kill -s HUP \$MAINPID
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=3

# Security hardening
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
    systemctl enable ekafy --quiet

    if file_exists "${BACKEND_DIR}/manage.py"; then
        systemctl restart ekafy
        sleep 2
        if svc_active ekafy; then
            log_info "ekafy.service is running ✔"
        else
            log_warn "ekafy.service failed to start — check: journalctl -u ekafy"
        fi
    else
        log_warn "No Django manage.py found — ekafy.service enabled but not started."
        log_warn "Deploy your code to ${BACKEND_DIR} then: systemctl start ekafy"
    fi
}

# ─── STEP 12: Nginx Configuration ────────────────────────────────────────────
step_12_nginx() {
    log_step "STEP 12/12 — Nginx Configuration"

    # Remove default site
    rm -f /etc/nginx/sites-enabled/default

    local nginx_conf="/etc/nginx/sites-available/ekafy"

    cat > "${nginx_conf}" <<NGINX
# =============================================================================
# EKAFY Nginx Configuration — Generated by installer v${EKAFY_VERSION}
# Date: $(_ts)
# =============================================================================

# Django/Gunicorn upstream
upstream django_backend {
    server 127.0.0.1:${GUNICORN_PORT} fail_timeout=5s;
    keepalive 32;
}

# Rate limiting zones
limit_req_zone \$binary_remote_addr zone=api_ratelimit:10m rate=60r/m;
limit_req_zone \$binary_remote_addr zone=dash_ratelimit:5m  rate=30r/m;
limit_req_zone \$binary_remote_addr zone=wp_ratelimit:5m    rate=100r/m;

# ── HTTP → HTTPS redirect (uncomment after running certbot) ─────────────────
# server {
#     listen 80;
#     server_name ${API_DOMAIN} ${BLOG_DOMAIN} ${DASH_DOMAIN};
#     return 301 https://\$host\$request_uri;
# }

# ─────────────────────────────────────────────────────────────────────────────
# api.${API_DOMAIN} → Django REST API
# ─────────────────────────────────────────────────────────────────────────────
server {
    listen 80;
    # listen 443 ssl http2;
    server_name ${API_DOMAIN};

    # SSL — uncomment after certbot
    # ssl_certificate     /etc/letsencrypt/live/${API_DOMAIN}/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/${API_DOMAIN}/privkey.pem;
    # include /etc/letsencrypt/options-ssl-nginx.conf;
    # ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    add_header X-Content-Type-Options  "nosniff"         always;
    add_header X-Frame-Options         "DENY"            always;
    add_header X-XSS-Protection        "1; mode=block"   always;
    add_header Referrer-Policy         "strict-origin"   always;

    client_max_body_size 10M;

    location /static/ {
        alias ${BACKEND_DIR}/staticfiles/;
        expires 30d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    location /media/ {
        alias ${BACKEND_DIR}/media/;
        expires 7d;
        access_log off;
    }

    location /nginx_status {
        stub_status on;
        allow 127.0.0.1;
        deny all;
    }

    location / {
        limit_req zone=api_ratelimit burst=30 nodelay;
        proxy_pass         http://django_backend;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_set_header   Connection        "";
        proxy_connect_timeout 10s;
        proxy_read_timeout    60s;
    }

    access_log /var/log/nginx/api.ekafy.access.log;
    error_log  /var/log/nginx/api.ekafy.error.log warn;
}

# ─────────────────────────────────────────────────────────────────────────────
# ${DASH_DOMAIN} → Django Admin Dashboard
# ─────────────────────────────────────────────────────────────────────────────
server {
    listen 80;
    # listen 443 ssl http2;
    server_name ${DASH_DOMAIN};

    # ssl_certificate     /etc/letsencrypt/live/${DASH_DOMAIN}/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/${DASH_DOMAIN}/privkey.pem;
    # include /etc/letsencrypt/options-ssl-nginx.conf;

    # Optional IP restriction — uncomment + set your IP:
    # allow YOUR.OFFICE.IP.HERE;
    # deny all;

    add_header X-Content-Type-Options  "nosniff"       always;
    add_header X-Frame-Options         "DENY"          always;
    add_header X-XSS-Protection        "1; mode=block" always;

    client_max_body_size 10M;

    location /static/ {
        alias ${BACKEND_DIR}/staticfiles/;
        expires 30d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    location / {
        limit_req zone=dash_ratelimit burst=10 nodelay;
        proxy_pass         http://django_backend;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_set_header   Connection        "";
        proxy_connect_timeout 10s;
        proxy_read_timeout    60s;
    }

    access_log /var/log/nginx/dashboard.ekafy.access.log;
    error_log  /var/log/nginx/dashboard.ekafy.error.log warn;
}

NGINX

    # Add WordPress server block only if installing WP
    if [[ "${INSTALL_WORDPRESS}" == "yes" ]]; then
        cat >> "${nginx_conf}" <<NGINX_WP
# ─────────────────────────────────────────────────────────────────────────────
# ${BLOG_DOMAIN} → WordPress (PHP-FPM)
# ─────────────────────────────────────────────────────────────────────────────
server {
    listen 80;
    # listen 443 ssl http2;
    server_name ${BLOG_DOMAIN};

    # ssl_certificate     /etc/letsencrypt/live/${BLOG_DOMAIN}/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/${BLOG_DOMAIN}/privkey.pem;
    # include /etc/letsencrypt/options-ssl-nginx.conf;

    root  ${WP_DIR};
    index index.php index.html;

    client_max_body_size 20M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass  unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include       fastcgi_params;
        fastcgi_read_timeout    300;
        fastcgi_connect_timeout  60;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        log_not_found off;
        access_log    off;
    }

    # Block sensitive files
    location ~ /\.            { deny all; access_log off; log_not_found off; }
    location ~* /wp-config\.php { deny all; }
    location ~* /xmlrpc\.php    { deny all; }
    location ~* /wp-admin/install\.php { allow all; }

    access_log /var/log/nginx/blog.ekafy.access.log;
    error_log  /var/log/nginx/blog.ekafy.error.log warn;
}
NGINX_WP
    fi

    # Enable site
    ln -sf "${nginx_conf}" /etc/nginx/sites-enabled/ekafy

    # Test + reload
    if nginx -t 2>/dev/null; then
        systemctl enable nginx --quiet
        systemctl reload nginx
        log_info "Nginx configuration applied and reloaded ✔"
    else
        nginx -t  # show the actual error
        log_error "Nginx config test failed! Check ${nginx_conf}"
        exit 1
    fi
}

# ─── FIREWALL ─────────────────────────────────────────────────────────────────
step_firewall() {
    log_step "FIREWALL — UFW"

    # ALWAYS allow SSH first to prevent lockout
    ufw allow 22/tcp    comment 'SSH' --force 2>/dev/null || ufw allow 22/tcp
    ufw allow 80/tcp    comment 'HTTP'
    ufw allow 443/tcp   comment 'HTTPS'

    # Block direct Gunicorn access from outside
    ufw deny "${GUNICORN_PORT}/tcp" comment 'Block direct Gunicorn' 2>/dev/null || true

    # Enable (non-interactive)
    ufw --force enable

    log_info "UFW enabled — allowed: 22 (SSH), 80 (HTTP), 443 (HTTPS)"
    ufw status numbered 2>/dev/null | head -20
}

# =============================================================================
# POST-INSTALL VALIDATION
# =============================================================================

validate_installation() {
    log_step "POST-INSTALL VALIDATION"
    echo ""

    local v_pass=0 v_fail=0 v_warn=0

    v_ok()   { log_ok   "  $1"; ((v_pass++)) || true; }
    v_fail() { log_fail "  $1"; ((v_fail++)) || true; }
    v_warn() { log_warn "  $1"; ((v_warn++)) || true; }

    # Services
    echo -e "  ${BOLD}Service Status:${RESET}"
    local services=("nginx" "postgresql" "ekafy")
    [[ "${INSTALL_WORDPRESS}" == "yes" ]] && services+=("mariadb" "php${PHP_VERSION}-fpm")
    [[ "${INSTALL_REDIS}" == "yes" ]]     && services+=("redis-server" "redis")

    for svc in "${services[@]}"; do
        if svc_active "${svc}" 2>/dev/null; then
            v_ok "${svc}: running ✔"
        else
            # Try alternate names
            local alt=""
            [[ "${svc}" == "redis" ]] && alt="redis-server"
            [[ "${svc}" == "redis-server" ]] && alt="redis"
            if [[ -n "${alt}" ]] && svc_active "${alt}" 2>/dev/null; then
                v_ok "${svc}: running as ${alt} ✔"
            else
                v_warn "${svc}: not running — may be optional or not yet started"
            fi
        fi
    done
    echo ""

    # Django API
    echo -e "  ${BOLD}Connectivity:${RESET}"
    if curl -s --max-time 5 "http://127.0.0.1:${GUNICORN_PORT}/" -o /dev/null 2>/dev/null; then
        v_ok "Django API responds on port ${GUNICORN_PORT} ✔"
    else
        v_warn "Django API not responding on port ${GUNICORN_PORT} (code may not be deployed yet)"
    fi

    if curl -s --max-time 3 "http://127.0.0.1/nginx_status" -o /dev/null 2>/dev/null; then
        v_ok "Nginx stub_status endpoint working ✔"
    else
        v_warn "Nginx stub_status not reachable (add to nginx config if needed)"
    fi
    echo ""

    # Files
    echo -e "  ${BOLD}Key Files:${RESET}"
    local key_files=(
        "${BACKEND_DIR}/.env"
        "/etc/nginx/sites-enabled/ekafy"
        "/etc/systemd/system/ekafy.service"
    )
    [[ "${INSTALL_WORDPRESS}" == "yes" ]] && key_files+=("${WP_DIR}/wp-config.php")

    for f in "${key_files[@]}"; do
        if file_exists "${f}"; then
            v_ok "${f} ✔"
        else
            v_fail "${f} MISSING"
        fi
    done
    echo ""

    # Summary
    echo -e "  ${BOLD}══════════════════════════════════════════${RESET}"
    echo -e "  ${GREEN}  ✔ Passed : ${v_pass}${RESET}"
    echo -e "  ${YELLOW}  ⚠ Warnings: ${v_warn}${RESET}"
    echo -e "  ${RED}  ✖ Failed : ${v_fail}${RESET}"
    echo -e "  ${BOLD}══════════════════════════════════════════${RESET}"
    echo ""
}

# =============================================================================
# FINAL SUMMARY
# =============================================================================

print_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════════════╗"
    echo "  ║              ✔  EKAFY INSTALLATION COMPLETE                    ║"
    echo "  ╠══════════════════════════════════════════════════════════════════╣"
    echo -e "  ║  ${CYAN}API       :${GREEN}  http://${API_DOMAIN}/api/v1/                  ║"
    echo -e "  ║  ${CYAN}Dashboard :${GREEN}  http://${DASH_DOMAIN}/dashboard/             ║"
    echo -e "  ║  ${CYAN}Blog      :${GREEN}  http://${BLOG_DOMAIN}/                        ║"
    echo -e "  ║  ${CYAN}Log file  :${GREEN}  ${LOGFILE}                ║"
    echo "  ╠══════════════════════════════════════════════════════════════════╣"
    echo "  ║                                                                  ║"
    echo "  ║  NEXT STEPS:                                                     ║"
    echo "  ║  1. Point DNS A records for all 3 domains to this VPS IP        ║"
    echo "  ║  2. Get IP: curl -4 ifconfig.me                                 ║"
    echo "  ║  3. Run SSL:                                                     ║"
    echo "  ║     apt install certbot python3-certbot-nginx -y                ║"
    echo -e "  ║     certbot --nginx -d ${API_DOMAIN} -d ${DASH_DOMAIN}   ║"
    echo "  ║  4. Create Django admin user:                                    ║"
    echo "  ║     cd ${BACKEND_DIR}                                            ║"
    echo "  ║     source venv/bin/activate                                     ║"
    echo "  ║     python manage.py createsuperuser                             ║"
    if [[ "${INSTALL_WORDPRESS}" == "yes" ]]; then
        echo "  ║  5. Complete WordPress setup:                                    ║"
        echo -e "  ║     http://${BLOG_DOMAIN}/wp-admin/install.php               ║"
    fi
    echo "  ║                                                                  ║"
    echo "  ╠══════════════════════════════════════════════════════════════════╣"
    echo "  ║  USEFUL COMMANDS:                                                ║"
    echo "  ║  systemctl status ekafy           - Check Django status         ║"
    echo "  ║  journalctl -u ekafy -f           - Live Django logs            ║"
    echo "  ║  tail -f ${LOGS_DIR}/django.log   - App log                     ║"
    echo "  ║  systemctl restart ekafy          - Restart API                 ║"
    echo "  ║  nginx -t && systemctl reload nginx - Reload Nginx              ║"
    echo "  ╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
    echo -e "  ${DIM}Full installation log: ${LOGFILE}${RESET}"
    echo ""
}

# =============================================================================
# REPLICATE TO ANOTHER VPS — helper info
# =============================================================================

print_replicate_guide() {
    echo ""
    echo -e "  ${BOLD}${MAGENTA}── REPLICATE TO ANOTHER VPS ──────────────────────────────────────${RESET}"
    echo ""
    echo -e "  ${CYAN}# Copy installer to new VPS:${RESET}"
    echo -e "  scp install.sh root@NEW_VPS_IP:/root/"
    echo ""
    echo -e "  ${CYAN}# Run on new VPS:${RESET}"
    echo -e "  ssh root@NEW_VPS_IP 'bash /root/install.sh'"
    echo ""
    echo -e "  ${CYAN}# Run check-only on new VPS first:${RESET}"
    echo -e "  ssh root@NEW_VPS_IP 'bash /root/install.sh --check-only'"
    echo ""
    echo -e "  ${CYAN}# Skip WordPress on API-only VPS:${RESET}"
    echo -e "  ssh root@NEW_VPS_IP 'bash /root/install.sh --no-wp'"
    echo ""
    echo -e "  ${BOLD}${MAGENTA}─────────────────────────────────────────────────────────────────${RESET}"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    print_banner
    check_requirements    # ← runs first, exits on hard failures
	
    
    step_02_dependencies
    step_03_user
    step_04_directories
    step_05_git_clone
    step_01_system_update
    step_06_python_env
    step_07_env_file
    step_08_postgresql
    step_09_django
    step_10_wordpress
    step_11_systemd
    step_12_nginx
    step_firewall

    validate_installation
    print_summary
    print_replicate_guide

    log_info "Installation completed at $(_ts)"
    log_info "Log saved to: ${LOGFILE}"
}

main "$@"
