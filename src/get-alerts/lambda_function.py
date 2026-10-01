"""GET /alerts — regresa todas las alertas registradas en SecurityAlerts.

Cada alerta sale con id, timestamp, host, log y severity:

    {"id": "openssh-1790032937#00003", "timestamp": "Dec 10 06:55:46",
     "host": "LabSZ", "log": "Invalid user webmaster from 173.234.31.186",
     "severity": "MEDIUM"}

Es un Scan paginado porque el endpoint pide *todas* las alertas; no hay una
llave por la cual hacer Query.
"""
import json
import os

import boto3

table = boto3.resource("dynamodb").Table(os.environ.get("SECURITY_ALERTS_TABLE_NAME", "SecurityAlerts"))


def to_alert(item: dict) -> dict:
    return {
        "id": item["sk"],
        "timestamp": item.get("syslog_timestamp", ""),
        "host": item.get("hostname", ""),
        "log": item.get("message", ""),
        "severity": item.get("severity", ""),
    }


def scan_all() -> list[dict]:
    items = []
    kwargs = {}
    while True:
        page = table.scan(**kwargs)
        items.extend(page["Items"])
        if "LastEvaluatedKey" not in page:
            return items
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]


def lambda_handler(event, context):
    # sk = <batch_id>#<linea> y batch_id = openssh-<epoch>, así que ordenar por
    # sk descendente deja las alertas más recientes primero.
    items = sorted(scan_all(), key=lambda item: item["sk"], reverse=True)
    alerts = [to_alert(item) for item in items]

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"count": len(alerts), "alerts": alerts}, ensure_ascii=False),
    }
