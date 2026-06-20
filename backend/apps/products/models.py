"""
Products App — Models
"""
from django.db import models


class ProductType(models.TextChoices):
    SOFTWARE = 'software', 'Software'
    HARDWARE = 'hardware', 'Hardware'
    SERVICE = 'service', 'Service'
    DIGITAL = 'digital', 'Digital'
    SUBSCRIPTION = 'subscription', 'Subscription'


class ProductStatus(models.TextChoices):
    ACTIVE = 'active', 'Active'
    INACTIVE = 'inactive', 'Inactive'
    DRAFT = 'draft', 'Draft'
    ARCHIVED = 'archived', 'Archived'


class Product(models.Model):
    """
    Core product entity for the Ekafy platform.
    """
    product_name = models.CharField(
        max_length=255,
        verbose_name='Product Name',
        help_text='Full name of the product',
    )
    product_type = models.CharField(
        max_length=50,
        choices=ProductType.choices,
        default=ProductType.SOFTWARE,
        verbose_name='Product Type',
    )
    description = models.TextField(
        blank=True,
        default='',
        verbose_name='Description',
    )
    status = models.CharField(
        max_length=20,
        choices=ProductStatus.choices,
        default=ProductStatus.DRAFT,
        verbose_name='Status',
        db_index=True,
    )
    created_at = models.DateTimeField(auto_now_add=True, verbose_name='Created At')
    updated_at = models.DateTimeField(auto_now=True, verbose_name='Updated At')

    class Meta:
        ordering = ['-created_at']
        verbose_name = 'Product'
        verbose_name_plural = 'Products'
        indexes = [
            models.Index(fields=['status', '-created_at']),
            models.Index(fields=['product_type']),
        ]

    def __str__(self):
        return f"{self.product_name} ({self.get_product_type_display()})"

    @property
    def is_active(self):
        return self.status == ProductStatus.ACTIVE
