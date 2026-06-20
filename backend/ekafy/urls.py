"""
EKAFY Master URL Configuration
"""
from django.contrib import admin
from django.urls import path, include
from django.conf import settings
from django.conf.urls.static import static
from rest_framework_simplejwt.views import (
    TokenObtainPairView,
    TokenRefreshView,
    TokenVerifyView,
)

# ─── API v1 URL patterns ─────────────────────────────────────────────────────
api_v1_patterns = [
    # Auth
    path('auth/token/', TokenObtainPairView.as_view(), name='token_obtain_pair'),
    path('auth/token/refresh/', TokenRefreshView.as_view(), name='token_refresh'),
    path('auth/token/verify/', TokenVerifyView.as_view(), name='token_verify'),

    # Products
    path('products/', include('apps.products.urls')),

    # Monitoring
    path('monitoring/', include('apps.monitoring.urls')),

    # System config
    path('config/', include('apps.system_config.urls')),
]

urlpatterns = [
    # Django admin
    path('admin/', admin.site.urls),

    # API v1
    path('api/v1/', include(api_v1_patterns)),

    # Dashboard (HTML views)
    path('dashboard/', include('apps.dashboard.urls')),
]

# Serve media in development
if settings.DEBUG:
    urlpatterns += static(settings.MEDIA_URL, document_root=settings.MEDIA_ROOT)
    urlpatterns += static(settings.STATIC_URL, document_root=settings.STATIC_ROOT)
