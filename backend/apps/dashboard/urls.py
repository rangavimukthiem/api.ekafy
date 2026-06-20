"""
Dashboard App — URLs
"""
from django.urls import path
from . import views

app_name = 'dashboard'

urlpatterns = [
    path('', views.dashboard_index, name='index'),
    path('login/', views.login_view, name='login'),
    path('logout/', views.logout_view, name='logout'),
    path('products/', views.products_view, name='products'),
    path('logs/', views.logs_view, name='logs'),
    path('services/', views.services_view, name='services'),

    # AJAX endpoints
    path('api/snapshot/', views.api_snapshot, name='api-snapshot'),
    path('api/service-control/', views.api_service_control, name='api-service-control'),
]
