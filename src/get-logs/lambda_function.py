"""GET /logs?top=N — regresa los últimos N logs guardados en la tabla Logs.

Hace Query (no Scan) sobre el GSI last_modified-index: todos los logs
comparten la partition key fija gsi_pk = "LOG" (la escribe la state machine
en WriteLog) y el sort key es el LastModified del batch en S3, así que con
ScanIndexForward=False y Limit=N DynamoDB regresa directo los N más recientes.
"""
import json
import os

import boto3
from boto3.dynamodb.conditions import Key

table = boto3.resource("dynamodb").Table(os.environ.get("LOGS_TABLE_NAME", "Logs"))
INDEX_NAME = os.environ.get("LOGS_RECENT_INDEX", "last_modified-index")
GSI_PK = "LOG"  # debe coincidir con gsi_pk en src/step-functions/state-machine.asl.json

DEFAULT_TOP = 10
MAX_TOP = 1000


def response(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, ensure_ascii=False),
    }


def to_log(item: dict) -> dict:
    return {
        "id": item["sk"],
        "timestamp": item.get("syslog_timestamp", ""),
        "host": item.get("hostname", ""),
        "log": item.get("message", ""),
        "event_type": item.get("event_type", ""),
        "last_modified": item.get("last_modified", ""),
    }


def query_same_last_modified(last_modified: str) -> list[dict]:
    items = []
    kwargs = {
        "IndexName": INDEX_NAME,
        "KeyConditionExpression": Key("gsi_pk").eq(GSI_PK) & Key("last_modified").eq(last_modified),
    }
    while True:
        page = table.query(**kwargs)
        items.extend(page["Items"])
        if "LastEvaluatedKey" not in page:
            return items
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]


def lambda_handler(event, context):
    params = event.get("queryStringParameters") or {}
    try:
        top = int(params.get("top", DEFAULT_TOP))
    except ValueError:
        return response(400, {"error": "top debe ser un número entero"})
    if not 1 <= top <= MAX_TOP:
        return response(400, {"error": f"top debe estar entre 1 y {MAX_TOP}"})

    items = table.query(
        IndexName=INDEX_NAME,
        KeyConditionExpression=Key("gsi_pk").eq(GSI_PK),
        ScanIndexForward=False,
        Limit=top,
    )["Items"]

    # Todas las líneas de un batch comparten el mismo LastModified y DynamoDB
    # no garantiza su orden entre sí: si el Limit corta a la mitad de un batch,
    # se traen las demás líneas de ese último batch para quedarse con las
    # más recientes, y se desempata por id (<batch>#<línea>).
    if len(items) == top:
        items = {item["sk"]: item for item in items + query_same_last_modified(items[-1]["last_modified"])}.values()
    items = sorted(items, key=lambda item: (item["last_modified"], item["sk"]), reverse=True)[:top]
    logs = [to_log(item) for item in items]

    return response(200, {"top": top, "count": len(logs), "logs": logs})
