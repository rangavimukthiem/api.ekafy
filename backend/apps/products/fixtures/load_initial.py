"""
Products App — Fixtures — ONE real test product (no dummy data)
"""
# This file is intentionally a Python fixture loader.
# Run via: python manage.py shell < apps/products/fixtures/load_initial.py

from apps.products.models import Product, ProductType, ProductStatus

if not Product.objects.exists():
    Product.objects.create(
        product_name='Ekafy Core API',
        product_type=ProductType.SOFTWARE,
        description=(
            'Core REST API service for the Ekafy platform. '
            'Provides product management, authentication, and system monitoring endpoints.'
        ),
        status=ProductStatus.ACTIVE,
    )
    print('✔ Initial product created.')
else:
    print('✔ Products already exist, skipping seed.')
