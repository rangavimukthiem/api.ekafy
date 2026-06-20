"""
System Config App — Apps Config
"""
from django.apps import AppConfig


class SystemConfigConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'apps.system_config'
    verbose_name = 'System Configuration'
