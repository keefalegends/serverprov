import json
import boto3
import psycopg2
import os
import logging
from urllib.parse import unquote
from datetime import datetime
from aws_xray_sdk.core import xray_recorder
from aws_xray_sdk.core import patch_all

patch_all()

logger = logging.getLogger()
logger.setLevel(logging.INFO)

secrets_client = boto3.client('secretsmanager')
stepfunctions_client = boto3.client('stepfunctions')

_db_credentials = None


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
            conn = psycopg2.connect(
                host=creds['host'],
                database=creds['dbname'],
                user=creds['username'],
                password=creds['password'],
                connect_timeout=10
            )
            return conn
        except Exception as e:
            if attempt == 2:
                raise e
            import time
            time.sleep(2 ** attempt)


def response(status_code, body):
    return {
        'statusCode': status_code,
        'headers': {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Headers': 'Content-Type,X-Api-Key',
            'Access-Control-Allow-Methods': 'GET,POST,PUT,DELETE,OPTIONS'
        },
        'body': json.dumps(body, default=str)
    }


def lambda_handler(event, context):
    logger.info(json.dumps({'event': event}))

    http_method = event.get('httpMethod', '')
    path = event.get('path', '')
    path_params = event.get('pathParameters') or {}
    query_params = event.get('queryStringParameters') or {}
    body = {}
    if event.get('body'):
        body = json.loads(event['body'])

    try:
        # GET /health is handled by health_check lambda, but just in case
        if path == '/health':
            return response(200, {'status': 'healthy'})

        # GET /customers
        if path == '/customers' and http_method == 'GET':
            return get_customers()

        # GET /products
        if path == '/products' and http_method == 'GET':
            return get_products()

        # GET /orders
        if path == '/orders' and http_method == 'GET':
            return get_orders(query_params)

        # POST /orders
        if path == '/orders' and http_method == 'POST':
            return create_order(body)

        # GET /orders/{id}
        if path.startswith('/orders/') and http_method == 'GET' and path_params.get('id'):
            return get_order(path_params['id'])

        # PUT /orders/{id}
        if path.startswith('/orders/') and http_method == 'PUT' and path_params.get('id'):
            return update_order(path_params['id'], body)

        # DELETE /orders/{id}
        if path.startswith('/orders/') and http_method == 'DELETE' and path_params.get('id'):
            return delete_order(path_params['id'])

        # GET /status/{id}
        if path.startswith('/status/') and http_method == 'GET':
            execution_arn = path_params.get('id') or path.split('/status/')[-1]
            execution_arn = unquote(execution_arn)  # decode %3A -> :
            return get_execution_status(execution_arn)

        return response(404, {'error': 'Route not found'})

    except Exception as e:
        logger.error(f"Error: {str(e)}", exc_info=True)
        return response(500, {'error': str(e)})


def get_customers():
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT customer_id, name, email, phone, created_at FROM customers WHERE deleted_at IS NULL ORDER BY created_at DESC")
            rows = cur.fetchall()
            cols = [d[0] for d in cur.description]
            customers = [dict(zip(cols, row)) for row in rows]
        return response(200, {'customers': customers, 'count': len(customers)})
    finally:
        conn.close()


def get_products():
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT product_id, name, category, price, stock_quantity, created_at FROM products WHERE deleted_at IS NULL ORDER BY category, name")
            rows = cur.fetchall()
            cols = [d[0] for d in cur.description]
            products = [dict(zip(cols, row)) for row in rows]
        return response(200, {'products': products, 'count': len(products)})
    finally:
        conn.close()


def get_orders(query_params):
    conn = get_db_connection()
    try:
        status_filter = query_params.get('status')
        limit = int(query_params.get('limit', 50))
        offset = int(query_params.get('offset', 0))

        with conn.cursor() as cur:
            if status_filter:
                cur.execute(
                    "SELECT o.*, c.name as customer_name FROM orders o LEFT JOIN customers c ON o.customer_id=c.customer_id WHERE o.status=%s AND o.deleted_at IS NULL ORDER BY o.created_at DESC LIMIT %s OFFSET %s",
                    (status_filter, limit, offset)
                )
            else:
                cur.execute(
                    "SELECT o.*, c.name as customer_name FROM orders o LEFT JOIN customers c ON o.customer_id=c.customer_id WHERE o.deleted_at IS NULL ORDER BY o.created_at DESC LIMIT %s OFFSET %s",
                    (limit, offset)
                )
            rows = cur.fetchall()
            cols = [d[0] for d in cur.description]
            orders = [dict(zip(cols, row)) for row in rows]
        return response(200, {'orders': orders, 'count': len(orders)})
    finally:
        conn.close()


def create_order(body):
    customer_id = body.get('customer_id')
    items = body.get('items', [])
    if not customer_id or not items:
        return response(400, {'error': 'customer_id and items are required'})

    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            # Calculate total amount
            total_amount = 0
            for item in items:
                cur.execute("SELECT price FROM products WHERE product_id=%s", (item['product_id'],))
                row = cur.fetchone()
                if not row:
                    return response(400, {'error': f"Product {item['product_id']} not found"})
                total_amount += row[0] * item['quantity']

            # Insert order
            order_id = f"ORD-{datetime.utcnow().strftime('%Y%m%d%H%M%S%f')[:18]}"
            cur.execute(
                "INSERT INTO orders (order_id, customer_id, total_amount, status, created_at) VALUES (%s, %s, %s, 'pending', NOW()) RETURNING order_id",
                (order_id, customer_id, total_amount)
            )
            # Insert order items
            for item in items:
                cur.execute(
                    "INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES (%s, %s, %s, (SELECT price FROM products WHERE product_id=%s))",
                    (order_id, item['product_id'], item['quantity'], item['product_id'])
                )
            conn.commit()

        # Start Step Functions execution
        sf_arn = os.environ.get('STEP_FUNCTIONS_ARN', '')
        execution_arn = ''
        if sf_arn:
            sf_response = stepfunctions_client.start_execution(
                stateMachineArn=sf_arn,
                name=f"order-{order_id}-{int(datetime.utcnow().timestamp())}",
                input=json.dumps({
                    'orderId': order_id,
                    'customerId': customer_id,
                    'items': items,
                    'totalAmount': float(total_amount)
                })
            )
            execution_arn = sf_response['executionArn']

        logger.info(json.dumps({'action': 'order_created', 'order_id': order_id}))
        return response(201, {'order_id': order_id, 'total_amount': float(total_amount), 'execution_arn': execution_arn, 'status': 'pending'})
    except Exception as e:
        conn.rollback()
        raise e
    finally:
        conn.close()


def get_order(order_id):
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT o.*, c.name as customer_name, c.email as customer_email FROM orders o LEFT JOIN customers c ON o.customer_id=c.customer_id WHERE o.order_id=%s AND o.deleted_at IS NULL",
                (order_id,)
            )
            row = cur.fetchone()
            if not row:
                return response(404, {'error': 'Order not found'})
            cols = [d[0] for d in cur.description]
            order = dict(zip(cols, row))

            cur.execute(
                "SELECT oi.*, p.name as product_name FROM order_items oi LEFT JOIN products p ON oi.product_id=p.product_id WHERE oi.order_id=%s",
                (order_id,)
            )
            items = cur.fetchall()
            item_cols = [d[0] for d in cur.description]
            order['items'] = [dict(zip(item_cols, i)) for i in items]

        return response(200, order)
    finally:
        conn.close()


def update_order(order_id, body):
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE orders SET status=%s, updated_at=NOW() WHERE order_id=%s AND deleted_at IS NULL RETURNING order_id",
                (body.get('status', 'pending'), order_id)
            )
            if not cur.fetchone():
                conn.rollback()
                return response(404, {'error': 'Order not found'})
            conn.commit()
        return response(200, {'message': 'Order updated', 'order_id': order_id})
    except Exception as e:
        conn.rollback()
        raise e
    finally:
        conn.close()


def delete_order(order_id):
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE orders SET deleted_at=NOW() WHERE order_id=%s AND deleted_at IS NULL RETURNING order_id",
                (order_id,)
            )
            if not cur.fetchone():
                conn.rollback()
                return response(404, {'error': 'Order not found'})
            conn.commit()
        return response(200, {'message': 'Order deleted (soft)', 'order_id': order_id})
    except Exception as e:
        conn.rollback()
        raise e
    finally:
        conn.close()


def get_execution_status(execution_arn):
    try:
        sf_response = stepfunctions_client.describe_execution(executionArn=execution_arn)
        return response(200, {
            'execution_arn': execution_arn,
            'status': sf_response['status'],
            'start_date': sf_response.get('startDate'),
            'stop_date': sf_response.get('stopDate'),
        })
    except Exception as e:
        return response(404, {'error': str(e)})
