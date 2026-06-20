"""
Products App — Serializers
"""
from rest_framework import serializers
from .models import Product, ProductType, ProductStatus


class ProductSerializer(serializers.ModelSerializer):
    product_type_display = serializers.CharField(
        source='get_product_type_display', read_only=True
    )
    status_display = serializers.CharField(
        source='get_status_display', read_only=True
    )
    is_active = serializers.BooleanField(read_only=True)

    class Meta:
        model = Product
        fields = [
            'id',
            'product_name',
            'product_type',
            'product_type_display',
            'description',
            'status',
            'status_display',
            'is_active',
            'created_at',
            'updated_at',
        ]
        read_only_fields = ['id', 'created_at', 'updated_at']

    def validate_product_name(self, value):
        if len(value.strip()) < 2:
            raise serializers.ValidationError(
                'Product name must be at least 2 characters.'
            )
        return value.strip()


class ProductCreateSerializer(serializers.ModelSerializer):
    class Meta:
        model = Product
        fields = [
            'product_name',
            'product_type',
            'description',
            'status',
        ]

    def validate_product_type(self, value):
        valid_types = [t.value for t in ProductType]
        if value not in valid_types:
            raise serializers.ValidationError(
                f'Invalid product type. Choose from: {valid_types}'
            )
        return value

    def validate_status(self, value):
        valid_statuses = [s.value for s in ProductStatus]
        if value not in valid_statuses:
            raise serializers.ValidationError(
                f'Invalid status. Choose from: {valid_statuses}'
            )
        return value
