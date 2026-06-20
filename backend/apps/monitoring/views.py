"""
Monitoring App — Views
"""
import logging
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated, IsAdminUser

from . import service

logger = logging.getLogger('apps.monitoring')


class SystemSnapshotView(APIView):
    """GET /api/v1/monitoring/snapshot/ — full real-time system metrics."""
    permission_classes = [IsAdminUser]

    def get(self, request):
        snapshot = service.get_system_snapshot()
        return Response(snapshot)


class CPUView(APIView):
    """GET /api/v1/monitoring/cpu/"""
    permission_classes = [IsAdminUser]

    def get(self, request):
        return Response({'cpu_percent': service.get_cpu_usage()})


class MemoryView(APIView):
    """GET /api/v1/monitoring/memory/"""
    permission_classes = [IsAdminUser]

    def get(self, request):
        return Response(service.get_memory_info())


class DiskView(APIView):
    """GET /api/v1/monitoring/disk/"""
    permission_classes = [IsAdminUser]

    def get(self, request):
        path = request.query_params.get('path', '/')
        # Only allow /srv or / paths to prevent traversal
        allowed_paths = ['/', '/srv', '/srv/ekafy', '/var', '/tmp']
        if path not in allowed_paths:
            path = '/'
        return Response(service.get_disk_info(path))


class UptimeView(APIView):
    """GET /api/v1/monitoring/uptime/"""
    permission_classes = [IsAdminUser]

    def get(self, request):
        return Response({
            'uptime': service.get_uptime(),
            'load_average': service.get_load_average(),
        })


class ServicesView(APIView):
    """GET /api/v1/monitoring/services/"""
    permission_classes = [IsAdminUser]

    def get(self, request):
        return Response({'services': service.get_all_service_statuses()})


class NetworkView(APIView):
    """GET /api/v1/monitoring/network/"""
    permission_classes = [IsAdminUser]

    def get(self, request):
        return Response({
            'connections': service.get_network_connections(),
            'nginx': service.get_nginx_connections(),
        })


class LogView(APIView):
    """
    GET /api/v1/monitoring/logs/
    Query params:
        log=django|nginx|error|install (maps to safe paths only)
    """
    permission_classes = [IsAdminUser]

    LOG_MAP = {
        'django': '/srv/ekafy/logs/django.log',
        'nginx_access': '/var/log/nginx/access.log',
        'nginx_error': '/var/log/nginx/error.log',
        'install': '/var/log/ekafy-install.log',
        'gunicorn': '/srv/ekafy/logs/gunicorn.log',
    }

    def get(self, request):
        log_key = request.query_params.get('log', 'django')
        if log_key not in self.LOG_MAP:
            return Response(
                {'error': f'Unknown log. Valid options: {list(self.LOG_MAP.keys())}'},
                status=400,
            )
        log_path = self.LOG_MAP[log_key]
        return Response(service.get_log_tail(log_path, lines=100))
