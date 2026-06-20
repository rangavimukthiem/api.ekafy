"""
EKAFY ASGI Configuration (for future async/WebSocket support)
"""
import os
from django.core.asgi import get_asgi_application

os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'ekafy.settings')
application = get_asgi_application()
