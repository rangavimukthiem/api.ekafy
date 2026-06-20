"""
Products App — Views
"""
import logging
from rest_framework import viewsets, filters, status
from rest_framework.decorators import action
from rest_framework.response import Response
from rest_framework.permissions import IsAuthenticated, IsAdminUser
from django_filters.rest_framework import DjangoFilterBackend

from .models import Product, ProductStatus
from .serializers import ProductSerializer, ProductCreateSerializer

logger = logging.getLogger('apps.products')


class ProductViewSet(viewsets.ModelViewSet):
    """
    CRUD endpoint for Products.

    list:   GET  /api/v1/products/
    create: POST /api/v1/products/
    detail: GET  /api/v1/products/{id}/
    update: PUT  /api/v1/products/{id}/
    patch:  PATCH /api/v1/products/{id}/
    delete: DELETE /api/v1/products/{id}/
    """
    queryset = Product.objects.all()
    serializer_class = ProductSerializer
    filter_backends = [filters.SearchFilter, filters.OrderingFilter]
    search_fields = ['product_name', 'description']
    ordering_fields = ['created_at', 'product_name', 'status']
    ordering = ['-created_at']

    def get_serializer_class(self):
        if self.action in ['create', 'update', 'partial_update']:
            return ProductCreateSerializer
        return ProductSerializer

    def get_permissions(self):
        if self.action in ['destroy']:
            return [IsAdminUser()]
        return [IsAuthenticated()]

    def get_queryset(self):
        qs = super().get_queryset()
        status_filter = self.request.query_params.get('status')
        product_type = self.request.query_params.get('product_type')
        if status_filter:
            qs = qs.filter(status=status_filter)
        if product_type:
            qs = qs.filter(product_type=product_type)
        return qs

    def perform_create(self, serializer):
        product = serializer.save()
        logger.info(f'Product created: {product.product_name} (id={product.id})')

    def perform_destroy(self, instance):
        logger.warning(f'Product deleted: {instance.product_name} (id={instance.id})')
        instance.delete()

    @action(detail=True, methods=['post'], url_path='activate')
    def activate(self, request, pk=None):
        """Set product status to active."""
        product = self.get_object()
        product.status = ProductStatus.ACTIVE
        product.save(update_fields=['status', 'updated_at'])
        return Response({'status': 'activated', 'id': product.id})

    @action(detail=True, methods=['post'], url_path='deactivate')
    def deactivate(self, request, pk=None):
        """Set product status to inactive."""
        product = self.get_object()
        product.status = ProductStatus.INACTIVE
        product.save(update_fields=['status', 'updated_at'])
        return Response({'status': 'deactivated', 'id': product.id})

    @action(detail=False, methods=['get'], url_path='summary')
    def summary(self, request):
        """Return counts grouped by status."""
        qs = Product.objects.all()
        data = {
            'total': qs.count(),
            'by_status': {
                s.value: qs.filter(status=s.value).count()
                for s in ProductStatus
            },
        }
        return Response(data)
