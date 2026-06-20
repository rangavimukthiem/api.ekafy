"""
System Config App — Views
"""
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework.permissions import IsAdminUser
from django.conf import settings
import platform
import sys


class SystemInfoView(APIView):
    """GET /api/v1/config/system-info/ — returns platform metadata."""
    permission_classes = [IsAdminUser]

    def get(self, request):
        return Response({
            'platform': platform.system(),
            'platform_release': platform.release(),
            'python_version': sys.version,
            'django_version': __import__('django').get_version(),
            'debug_mode': settings.DEBUG,
            'time_zone': settings.TIME_ZONE,
        })
