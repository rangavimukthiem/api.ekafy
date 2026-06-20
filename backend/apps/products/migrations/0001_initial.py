"""
Products app — initial migration
"""
from django.db import migrations, models


class Migration(migrations.Migration):

    initial = True

    dependencies = []

    operations = [
        migrations.CreateModel(
            name='Product',
            fields=[
                ('id', models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name='ID')),
                ('product_name', models.CharField(help_text='Full name of the product', max_length=255, verbose_name='Product Name')),
                ('product_type', models.CharField(
                    choices=[('software','Software'),('hardware','Hardware'),('service','Service'),('digital','Digital'),('subscription','Subscription')],
                    default='software',
                    max_length=50,
                    verbose_name='Product Type',
                )),
                ('description', models.TextField(blank=True, default='', verbose_name='Description')),
                ('status', models.CharField(
                    choices=[('active','Active'),('inactive','Inactive'),('draft','Draft'),('archived','Archived')],
                    db_index=True,
                    default='draft',
                    max_length=20,
                    verbose_name='Status',
                )),
                ('created_at', models.DateTimeField(auto_now_add=True, verbose_name='Created At')),
                ('updated_at', models.DateTimeField(auto_now=True, verbose_name='Updated At')),
            ],
            options={
                'verbose_name': 'Product',
                'verbose_name_plural': 'Products',
                'ordering': ['-created_at'],
                'indexes': [
                    models.Index(fields=['status', '-created_at'], name='products_pr_status_created_idx'),
                    models.Index(fields=['product_type'], name='products_pr_type_idx'),
                ],
            },
        ),
    ]
