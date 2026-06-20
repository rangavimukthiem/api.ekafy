"""
Monitoring App — Core Service

All metrics are collected from real Linux system commands.
No mock or dummy data is ever returned.
"""
import subprocess
import shutil
import logging
import re
from pathlib import Path
from typing import Optional

logger = logging.getLogger('apps.monitoring')


def _run(cmd: list[str], timeout: int = 5) -> str:
    """
    Execute a shell command safely.
    - Uses list form (no shell=True) to prevent injection.
    - Returns stdout stripped, empty string on failure.
    """
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError, PermissionError) as exc:
        logger.warning(f'Command {cmd} failed: {exc}')
        return ''


# ─── CPU ─────────────────────────────────────────────────────────────────────

def get_cpu_usage() -> float:
    """
    Returns current CPU usage as a percentage (0-100).
    Uses /proc/stat with two reads 0.1s apart for accuracy.
    """
    try:
        import time

        def _read_cpu():
            with open('/proc/stat') as f:
                line = f.readline()
            parts = list(map(int, line.split()[1:]))
            idle = parts[3]
            total = sum(parts)
            return idle, total

        idle1, total1 = _read_cpu()
        time.sleep(0.1)
        idle2, total2 = _read_cpu()
        delta_idle = idle2 - idle1
        delta_total = total2 - total1
        if delta_total == 0:
            return 0.0
        usage = 100.0 * (1 - delta_idle / delta_total)
        return round(usage, 2)
    except Exception as exc:
        logger.warning(f'CPU read failed: {exc}')
        return 0.0


# ─── RAM ─────────────────────────────────────────────────────────────────────

def get_memory_info() -> dict:
    """
    Returns memory stats from /proc/meminfo.
    """
    try:
        data = {}
        with open('/proc/meminfo') as f:
            for line in f:
                key, val = line.split(':')
                data[key.strip()] = int(val.strip().split()[0])  # kB

        total_kb = data.get('MemTotal', 0)
        available_kb = data.get('MemAvailable', 0)
        used_kb = total_kb - available_kb

        total_mb = round(total_kb / 1024, 1)
        used_mb = round(used_kb / 1024, 1)
        available_mb = round(available_kb / 1024, 1)
        percent = round((used_kb / total_kb) * 100, 2) if total_kb else 0.0

        return {
            'total_mb': total_mb,
            'used_mb': used_mb,
            'available_mb': available_mb,
            'percent': percent,
        }
    except Exception as exc:
        logger.warning(f'Memory read failed: {exc}')
        return {'total_mb': 0, 'used_mb': 0, 'available_mb': 0, 'percent': 0.0}


# ─── DISK ────────────────────────────────────────────────────────────────────

def get_disk_info(path: str = '/') -> dict:
    """
    Returns disk usage for the given mount point using shutil.
    """
    try:
        usage = shutil.disk_usage(path)
        total_gb = round(usage.total / (1024 ** 3), 2)
        used_gb = round(usage.used / (1024 ** 3), 2)
        free_gb = round(usage.free / (1024 ** 3), 2)
        percent = round((usage.used / usage.total) * 100, 2) if usage.total else 0.0
        return {
            'path': path,
            'total_gb': total_gb,
            'used_gb': used_gb,
            'free_gb': free_gb,
            'percent': percent,
        }
    except Exception as exc:
        logger.warning(f'Disk read failed: {exc}')
        return {'path': path, 'total_gb': 0, 'used_gb': 0, 'free_gb': 0, 'percent': 0.0}


# ─── LOAD AVERAGE ────────────────────────────────────────────────────────────

def get_load_average() -> dict:
    """
    Returns 1, 5, and 15 minute load averages from /proc/loadavg.
    """
    try:
        with open('/proc/loadavg') as f:
            parts = f.read().strip().split()
        return {
            '1min': float(parts[0]),
            '5min': float(parts[1]),
            '15min': float(parts[2]),
        }
    except Exception as exc:
        logger.warning(f'Load average read failed: {exc}')
        return {'1min': 0.0, '5min': 0.0, '15min': 0.0}


# ─── UPTIME ──────────────────────────────────────────────────────────────────

def get_uptime() -> dict:
    """
    Returns system uptime from /proc/uptime.
    """
    try:
        with open('/proc/uptime') as f:
            seconds_up = float(f.read().split()[0])

        days = int(seconds_up // 86400)
        hours = int((seconds_up % 86400) // 3600)
        minutes = int((seconds_up % 3600) // 60)
        return {
            'seconds': int(seconds_up),
            'days': days,
            'hours': hours,
            'minutes': minutes,
            'human': f'{days}d {hours}h {minutes}m',
        }
    except Exception as exc:
        logger.warning(f'Uptime read failed: {exc}')
        return {'seconds': 0, 'days': 0, 'hours': 0, 'minutes': 0, 'human': 'unknown'}


# ─── SERVICE STATUS ───────────────────────────────────────────────────────────

def get_service_status(service_name: str) -> dict:
    """
    Returns real systemctl status for a given service.
    """
    output = _run(['systemctl', 'is-active', service_name])
    is_active = output == 'active'
    return {
        'service': service_name,
        'status': output or 'unknown',
        'active': is_active,
    }


def get_all_service_statuses() -> list[dict]:
    """
    Returns statuses for all monitored services.
    """
    services = [
        'ekafy',          # Gunicorn Django
        'nginx',
        'postgresql',
        'redis',
        'php8.2-fpm',
    ]
    return [get_service_status(s) for s in services]


# ─── NETWORK ─────────────────────────────────────────────────────────────────

def get_network_connections() -> dict:
    """
    Returns active TCP connection count from /proc/net/tcp and /proc/net/tcp6.
    """
    try:
        count = 0
        for tcp_file in ['/proc/net/tcp', '/proc/net/tcp6']:
            p = Path(tcp_file)
            if p.exists():
                lines = p.read_text().strip().split('\n')
                # Skip header, count ESTABLISHED (state=01)
                for line in lines[1:]:
                    parts = line.split()
                    if len(parts) >= 4 and parts[3] == '01':
                        count += 1
        return {'established_connections': count}
    except Exception as exc:
        logger.warning(f'Network read failed: {exc}')
        return {'established_connections': 0}


def get_nginx_connections() -> dict:
    """
    Reads Nginx active connections from stub_status if available,
    otherwise returns -1 to indicate unavailability.
    """
    output = _run(['curl', '-s', '--max-time', '2', 'http://127.0.0.1/nginx_status'])
    if not output:
        return {'active': -1, 'note': 'nginx_status not available'}

    match = re.search(r'Active connections:\s+(\d+)', output)
    if match:
        return {'active': int(match.group(1))}
    return {'active': -1, 'note': 'could not parse nginx_status'}


# ─── LOG READER ──────────────────────────────────────────────────────────────

def get_log_tail(log_path: str, lines: int = 100) -> dict:
    """
    Returns last N lines from a log file safely.
    """
    p = Path(log_path)
    if not p.exists():
        return {'log_path': log_path, 'lines': [], 'error': 'File not found'}
    if not p.is_file():
        return {'log_path': log_path, 'lines': [], 'error': 'Not a file'}

    try:
        output = _run(['tail', '-n', str(lines), str(p)])
        return {
            'log_path': log_path,
            'lines': output.splitlines(),
            'line_count': len(output.splitlines()),
        }
    except Exception as exc:
        return {'log_path': log_path, 'lines': [], 'error': str(exc)}


# ─── FULL SNAPSHOT ───────────────────────────────────────────────────────────

def get_system_snapshot() -> dict:
    """
    Returns a full real-time system snapshot.
    All values come from live system state.
    """
    return {
        'cpu': {
            'percent': get_cpu_usage(),
        },
        'memory': get_memory_info(),
        'disk': get_disk_info('/'),
        'load_average': get_load_average(),
        'uptime': get_uptime(),
        'services': get_all_service_statuses(),
        'network': {
            **get_network_connections(),
            **get_nginx_connections(),
        },
    }
