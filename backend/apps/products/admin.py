"""
Products App — Admin
"""
from django.contrib import admin
from .models import Product


@admin.register(Product)
class ProductAdmin(admin.ModelAdmin):
    list_display = ['product_name', 'product_type', 'status', 'is_active', 'created_at', 'updated_at']
    list_filter = ['status', 'product_type']
    search_fields = ['product_name', 'description']
    ordering = ['-created_at']
    readonly_fields = ['created_at', 'updated_at']
    fieldsets = (
        ('Basic Information', {
            'fields': ('product_name', 'product_type', 'description'),
        }),
        ('Status & Timestamps', {
            'fields': ('status', 'created_at', 'updated_at'),
        }),
    )
