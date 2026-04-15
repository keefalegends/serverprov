import json
import boto3
import psycopg2
import os
import logging
import time
from datetime import datetime
from aws_xray_sdk.core import xray_recorder
from aws_xray_sdk.core import patch_all

patch_all()

logger = logging.getLogger()
logger.setLevel(logging.INFO)

secrets_client = boto3.client('secretsmanager')
eventbridge_client = boto3.client('events')

_db_credentials = None
LOW_STOCK_THRESHOLD = int(os.environ.get('LOW_STOCK_THRESHOLD', 5))


def get_db_credentials():
    global _db_credentials
    if _db_credentials:
        return _db_credentials
    secret_arn = os.environ['SECRET_ARN']
    response = secrets_client.get_secret_value(SecretId=secret_arn)
    _db_credentials = json.loads(response['SecretString'])
    return _db_credentials


def get_db_connection():
    creds = get_db_credentials()
    for attempt in range(3):
        try:
            return psycopg2.connect(
                host=creds['host'],
                database=creds['dbname'],
                user=creds['username'],
                password=creds['password'],
                connect_timeout=10
            )
        except Exception as e:
            if attempt == 2:
                raise e
            time.sleep(2 ** attempt)


def lambda_handler(event, context):
    logger.info(json.dumps({'event': event, 'action': 'update_inventory_start'}))

    # EventBridge hourly check (no order context)
    if 'source' in event and event.get('source') == 'aws.events':
        return check_all_inventory()

    order_id = event.get('orderId')
    items = event.get('items', [])

    if not items:
        return {**event, 'inventoryResult': {'inventoryStatus': 'skipped', 'reason': 'no items'}}

    conn = get_db_connection()
    updated_items = []
    low_stock_products = []

    try:
        with conn.cursor() as cur:
            for item in items:
                product_id = item['product_id']
                quantity = item['quantity']

                # Pessimistic lock - FOR UPDATE
                cur.execute(
                    "SELECT product_id, name, stock_quantity FROM products WHERE product_id=%s FOR UPDATE",
                    (product_id,)
                )
                row = cur.fetchone()
                if not row:
                    conn.rollback()
                    return {**event, 'inventoryResult': {
                        'inventoryStatus': 'failed',
                        'error': f'Product {product_id} not found'
                    }}

                current_stock = row[2]
                product_name = row[1]

                if current_stock < quantity:
                    conn.rollback()
                    return {**event, 'inventoryResult': {
                        'inventoryStatus': 'insufficient_stock',
                        'product_id': product_id,
                        'available': current_stock,
                        'requested': quantity
                    }}

                new_stock = current_stock - quantity
                cur.execute(
                    "UPDATE products SET stock_quantity=%s, updated_at=NOW() WHERE product_id=%s",
                    (new_stock, product_id)
                )

                updated_items.append({
                    'product_id': product_id,
                    'product_name': product_name,
                    'previous_stock': current_stock,
                    'new_stock': new_stock
                })

                if new_stock <= LOW_STOCK_THRESHOLD:
                    low_stock_products.append({'product_id': product_id, 'product_name': product_name, 'stock': new_stock})

            # Update order status
            if order_id:
                cur.execute(
                    "UPDATE orders SET status='inventory_updated', updated_at=NOW() WHERE order_id=%s",
                    (order_id,)
                )

            conn.commit()

        # Publish low stock events
        for product in low_stock_products:
            publish_low_stock_event(product)

        logger.info(json.dumps({'action': 'inventory_updated', 'order_id': order_id, 'items': len(updated_items)}))

        return {**event, 'inventoryResult': {
            'inventoryStatus': 'success',
            'updatedItems': updated_items,
            'lowStockAlerts': low_stock_products
        }}

    except Exception as e:
        conn.rollback()
        logger.error(f"Inventory update failed: {e}")
        raise e
    finally:
        conn.close()


def check_all_inventory():
    """Hourly check - scan all products for low stock"""
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT product_id, name, stock_quantity FROM products WHERE stock_quantity <= %s AND deleted_at IS NULL",
                (LOW_STOCK_THRESHOLD,)
            )
            rows = cur.fetchall()
            low_stock = [{'product_id': r[0], 'product_name': r[1], 'stock': r[2]} for r in rows]

        for product in low_stock:
            publish_low_stock_event(product)

        logger.info(json.dumps({'action': 'hourly_inventory_check', 'low_stock_count': len(low_stock)}))
        return {'statusCode': 200, 'low_stock_products': low_stock}
    finally:
        conn.close()


def publish_low_stock_event(product):
    try:
        eventbridge_client.put_events(Entries=[{
            'Source': 'techno.order.system',
            'DetailType': 'InventoryLowStock',
            'Detail': json.dumps({
                'product_id': product['product_id'],
                'product_name': product['product_name'],
                'current_stock': product['stock'],
                'threshold': LOW_STOCK_THRESHOLD,
                'timestamp': datetime.utcnow().isoformat()
            }),
            'EventBusName': 'default'
        }])
    except Exception as e:
        logger.warning(f"Failed to publish low stock event: {e}")
