import json
import boto3
import os
import logging
import time
from datetime import datetime
from aws_xray_sdk.core import patch_all

patch_all()

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sns_client = boto3.client('sns')
SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN', '')


TEMPLATES = {
    'order_confirmation': {
        'subject': '✅ Order Confirmed - {order_id}',
        'message': 'Your order {order_id} has been confirmed. Total: ${total_amount}. Thank you!'
    },
    'payment_failed': {
        'subject': '❌ Payment Failed - {order_id}',
        'message': 'Payment for order {order_id} has failed. Please try again or contact support.'
    },
    'low_stock': {
        'subject': '⚠️ Low Stock Alert - {product_name}',
        'message': 'Product "{product_name}" (ID: {product_id}) is running low. Current stock: {current_stock} units.'
    },
    'system_error': {
        'subject': '🚨 System Error Alert',
        'message': 'A system error occurred: {error_message}. Please investigate immediately.'
    },
    'report_ready': {
        'subject': '📊 Daily Report Ready',
        'message': 'Your daily report is ready. Download it here: {presigned_url} (valid for 24 hours).'
    },
    'deployment': {
        'subject': '🚀 Deployment {status} - {environment}',
        'message': 'Deployment to {environment} has {status}. Pipeline: {pipeline_name}.'
    },
    'inventory_failed': {
        'subject': '⚠️ Inventory Update Failed - {order_id}',
        'message': 'Inventory update failed for order {order_id}. Product {product_id} has insufficient stock ({available} available, {requested} requested).'
    }
}


def format_notification(notification_type, data):
    template = TEMPLATES.get(notification_type, {
        'subject': f'Notification: {notification_type}',
        'message': json.dumps(data)
    })
    try:
        subject = template['subject'].format(**data)
        message = template['message'].format(**data)
    except KeyError:
        subject = f"Notification: {notification_type}"
        message = json.dumps(data, indent=2)
    return subject, message


def send_with_retry(subject, message, max_attempts=3):
    for attempt in range(max_attempts):
        try:
            sns_client.publish(
                TopicArn=SNS_TOPIC_ARN,
                Subject=subject[:100],  # SNS subject max 100 chars
                Message=message,
                MessageAttributes={
                    'notification_type': {
                        'DataType': 'String',
                        'StringValue': subject
                    }
                }
            )
            return True
        except Exception as e:
            if attempt == max_attempts - 1:
                raise e
            wait = (2 ** attempt) + 0.5
            logger.warning(f"SNS publish attempt {attempt+1} failed: {e}, retrying in {wait}s")
            time.sleep(wait)
    return False


def lambda_handler(event, context):
    logger.info(json.dumps({'event': event, 'action': 'send_notification_start'}))

    # Handle EventBridge events (InventoryLowStock)
    if event.get('source') == 'techno.order.system':
        detail = event.get('detail', {})
        notification_type = 'low_stock'
        data = {
            'product_id': detail.get('product_id', ''),
            'product_name': detail.get('product_name', 'Unknown'),
            'current_stock': detail.get('current_stock', 0),
        }
    else:
        # Direct invocation from Step Functions or other sources
        notification_type = event.get('notificationType', 'order_confirmation')
        data = event.get('data', event)

    try:
        subject, message = format_notification(notification_type, data)
        send_with_retry(subject, message)

        logger.info(json.dumps({
            'action': 'notification_sent',
            'type': notification_type,
            'subject': subject
        }))

        return {
            **event,
            'notificationResult': {
                'status': 'sent',
                'type': notification_type,
                'timestamp': datetime.utcnow().isoformat()
            }
        }

    except Exception as e:
        logger.error(f"Notification failed: {e}")
        return {
            **event,
            'notificationResult': {
                'status': 'failed',
                'error': str(e),
                'timestamp': datetime.utcnow().isoformat()
            }
        }
