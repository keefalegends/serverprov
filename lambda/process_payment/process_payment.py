import json
import boto3
import psycopg2
import os
import logging
import time
import random
from datetime import datetime
from aws_xray_sdk.core import xray_recorder
from aws_xray_sdk.core import patch_all

patch_all()

logger = logging.getLogger()
logger.setLevel(logging.INFO)

secrets_client = boto3.client('secretsmanager')
dynamodb = boto3.resource('dynamodb')

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


def check_idempotency(order_id):
    """Check DynamoDB for idempotency - prevent double payment"""
    table_name = os.environ.get('IDEMPOTENCY_TABLE', 'techno-payment-idempotency')
    try:
        table = dynamodb.Table(table_name)
        response = table.get_item(Key={'order_id': order_id})
        return response.get('Item')
    except Exception as e:
        logger.warning(f"Idempotency check failed: {e}")
        return None


def save_idempotency(order_id, result):
    table_name = os.environ.get('IDEMPOTENCY_TABLE', 'techno-payment-idempotency')
    try:
        table = dynamodb.Table(table_name)
        table.put_item(Item={
            'order_id': order_id,
            'result': result,
            'created_at': datetime.utcnow().isoformat(),
            'ttl': int(time.time()) + 86400  # 24 hours TTL
        })
    except Exception as e:
        logger.warning(f"Failed to save idempotency: {e}")


def validate_payment_amount(total_amount):
    if total_amount <= 0:
        raise ValueError(f"Invalid payment amount: {total_amount}")
    if total_amount > 1_000_000:
        raise ValueError(f"Payment amount exceeds maximum limit: {total_amount}")


def process_payment_with_retry(order_id, total_amount):
    """Simulate payment processing with exponential backoff retry"""
    max_attempts = 3
    for attempt in range(max_attempts):
        try:
            # Simulate payment gateway call
            # In real implementation, call actual payment gateway API
            payment_success = random.random() > 0.1  # 90% success rate simulation
            
            if payment_success:
                transaction_id = f"TXN-{order_id}-{int(time.time())}"
                return {
                    'paymentStatus': 'success',
                    'transactionId': transaction_id,
                    'amount': total_amount,
                    'processedAt': datetime.utcnow().isoformat()
                }
            else:
                raise Exception("Payment gateway declined")
        except Exception as e:
            if attempt == max_attempts - 1:
                return {
                    'paymentStatus': 'failed',
                    'error': str(e),
                    'amount': total_amount,
                    'processedAt': datetime.utcnow().isoformat()
                }
            wait_time = (2 ** attempt) + random.uniform(0, 1)
            logger.warning(f"Payment attempt {attempt + 1} failed, retrying in {wait_time:.2f}s")
            time.sleep(wait_time)


def lambda_handler(event, context):
    logger.info(json.dumps({'event': event, 'action': 'process_payment_start'}))

    order_id = event.get('orderId')
    total_amount = float(event.get('totalAmount', 0))

    try:
        validate_payment_amount(total_amount)
    except ValueError as e:
        logger.error(f"Payment validation failed: {e}")
        return {**event, 'paymentResult': {'paymentStatus': 'failed', 'error': str(e)}}

    # Idempotency check
    existing = check_idempotency(order_id)
    if existing:
        logger.info(f"Idempotent response for order {order_id}")
        return {**event, 'paymentResult': existing['result']}

    # Process payment
    payment_result = process_payment_with_retry(order_id, total_amount)

    # Update order status in DB
    if payment_result['paymentStatus'] == 'success':
        try:
            conn = get_db_connection()
            with conn.cursor() as cur:
                cur.execute(
                    "UPDATE orders SET status='payment_processed', payment_transaction_id=%s, updated_at=NOW() WHERE order_id=%s",
                    (payment_result['transactionId'], order_id)
                )
                conn.commit()
            conn.close()
        except Exception as e:
            logger.error(f"DB update failed: {e}")

    save_idempotency(order_id, payment_result)

    logger.info(json.dumps({
        'action': 'payment_processed',
        'order_id': order_id,
        'status': payment_result['paymentStatus']
    }))

    return {**event, 'paymentResult': payment_result}
