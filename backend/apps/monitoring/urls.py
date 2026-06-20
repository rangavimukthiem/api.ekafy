"""
Monitoring App — URLs
"""
from django.urls import path
from . import views

urlpatterns = [
    path('snapshot/', views.SystemSnapshotView.as_view(), name='monitoring-snapshot'),
    path('cpu/', views.CPUView.as_view(), name='monitoring-cpu'),
    path('memory/', views.MemoryView.as_view(), name='monitoring-memory'),
    path('disk/', views.DiskView.as_view(), name='monitoring-disk'),
    path('uptime/', views.UptimeView.as_view(), name='monitoring-uptime'),
    path('services/', views.ServicesView.as_view(), name='monitoring-services'),
    path('network/', views.NetworkView.as_view(), name='monitoring-network'),
    path('logs/', views.LogView.as_view(), name='monitoring-logs'),
]
