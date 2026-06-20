"""
Dashboard App — Service Control

Safe wrapper around systemctl commands.
Only pre-approved service names and actions are allowed.
No raw shell commands from user input ever reach this layer.
"""
import subprocess
import logging

logger = logging.getLogger('apps.dashboard')

# ─── STRICT ALLOWLISTS ────────────────────────────────────────────────────────
ALLOWED_SERVICES = frozenset(['ekafy', 'nginx', 'postgresql', 'redis', 'php8.2-fpm'])
ALLOWED_ACTIONS = frozenset(['restart', 'stop', 'start', 'status'])


def control_service(service: str, action: str) -> dict:
    """
    Execute a systemctl action on an approved service.

    Raises ValueError for unknown service/action.
    Uses subprocess list form — no shell injection possible.
    """
    if service not in ALLOWED_SERVICES:
        raise ValueError(f'Service "{service}" is not in the approved service list.')
    if action not in ALLOWED_ACTIONS:
        raise ValueError(f'Action "{action}" is not allowed.')

    logger.info(f'Dashboard: systemctl {action} {service}')

    try:
        result = subprocess.run(
            ['systemctl', action, service],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        return {
            'service': service,
            'action': action,
            'return_code': result.returncode,
            'stdout': result.stdout.strip(),
            'stderr': result.stderr.strip(),
            'success': result.returncode == 0,
        }
    except subprocess.TimeoutExpired:
        return {
            'service': service,
            'action': action,
            'return_code': -1,
            'stdout': '',
            'stderr': 'Command timed out',
            'success': False,
        }
    except PermissionError:
        return {
            'service': service,
            'action': action,
            'return_code': -1,
            'stdout': '',
            'stderr': 'Permission denied. Ekafy user needs sudo rights for systemctl.',
            'success': False,
        }
