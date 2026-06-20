"""
Dashboard App — Views
HTML dashboard rendered server-side. Session-authenticated only.
"""
import json
import logging
from functools import wraps

from django.contrib.auth import authenticate, login, logout
from django.contrib.auth.decorators import login_required, user_passes_test
from django.http import HttpResponseForbidden, JsonResponse
from django.shortcuts import redirect, render
from django.views.decorators.csrf import csrf_protect
from django.views.decorators.http import require_POST, require_GET

from apps.monitoring import service as monitor
from apps.products.models import Product
from .service_control import control_service, ALLOWED_SERVICES, ALLOWED_ACTIONS

logger = logging.getLogger('apps.dashboard')


def staff_required(view_func):
    """Decorator: user must be authenticated AND staff."""
    @wraps(view_func)
    def wrapper(request, *args, **kwargs):
        if not request.user.is_authenticated:
            return redirect(f'/dashboard/login/?next={request.path}')
        if not request.user.is_staff:
            return HttpResponseForbidden('Staff access required.')
        return view_func(request, *args, **kwargs)
    return wrapper


# ─── Auth Views ───────────────────────────────────────────────────────────────

@csrf_protect
def login_view(request):
    """POST: authenticate with username/password, redirect to dashboard."""
    error = None
    if request.method == 'POST':
        username = request.POST.get('username', '').strip()
        password = request.POST.get('password', '')
        user = authenticate(request, username=username, password=password)
        if user and user.is_staff:
            login(request, user)
            next_url = request.GET.get('next', '/dashboard/')
            return redirect(next_url)
        error = 'Invalid credentials or insufficient permissions.'
        logger.warning(f'Failed dashboard login attempt for user: {username}')
    return render(request, 'dashboard/login.html', {'error': error})


@require_POST
def logout_view(request):
    logout(request)
    return redirect('/dashboard/login/')


# ─── Dashboard Main ───────────────────────────────────────────────────────────

@staff_required
def dashboard_index(request):
    """Main dashboard: system snapshot + product list."""
    snapshot = monitor.get_system_snapshot()
    products = Product.objects.all().order_by('-created_at')[:10]
    return render(request, 'dashboard/index.html', {
        'snapshot': snapshot,
        'products': products,
        'page': 'dashboard',
    })


@staff_required
def products_view(request):
    """Full product list view."""
    products = Product.objects.all().order_by('-created_at')
    return render(request, 'dashboard/products.html', {
        'products': products,
        'page': 'products',
    })


@staff_required
def logs_view(request):
    """Log viewer — picks log from query param."""
    log_key = request.GET.get('log', 'django')
    LOG_MAP = {
        'django': '/srv/ekafy/logs/django.log',
        'nginx_access': '/var/log/nginx/access.log',
        'nginx_error': '/var/log/nginx/error.log',
        'install': '/var/log/ekafy-install.log',
        'gunicorn': '/srv/ekafy/logs/gunicorn.log',
    }
    if log_key not in LOG_MAP:
        log_key = 'django'
    log_data = monitor.get_log_tail(LOG_MAP[log_key], lines=100)
    return render(request, 'dashboard/logs.html', {
        'log_data': log_data,
        'log_key': log_key,
        'available_logs': list(LOG_MAP.keys()),
        'page': 'logs',
    })


@staff_required
def services_view(request):
    """Service control panel."""
    services = monitor.get_all_service_statuses()
    return render(request, 'dashboard/services.html', {
        'services': services,
        'allowed_actions': list(ALLOWED_ACTIONS - {'status'}),
        'page': 'services',
    })


# ─── AJAX Endpoints ───────────────────────────────────────────────────────────

@staff_required
def api_snapshot(request):
    """AJAX: returns fresh system snapshot as JSON for live updating."""
    snapshot = monitor.get_system_snapshot()
    return JsonResponse(snapshot)


@staff_required
@require_POST
@csrf_protect
def api_service_control(request):
    """AJAX: POST {service, action} — controls a service safely."""
    try:
        body = json.loads(request.body)
        service_name = body.get('service', '')
        action = body.get('action', '')
        result = control_service(service_name, action)
        return JsonResponse(result)
    except ValueError as exc:
        return JsonResponse({'error': str(exc), 'success': False}, status=400)
    except Exception as exc:
        logger.error(f'Service control error: {exc}')
        return JsonResponse({'error': 'Internal error', 'success': False}, status=500)
