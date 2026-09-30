"""Parse batch Lambda.

Descarga un archivo .log de S3 (bucket y key provistos en el evento por
EventBridge o Step Functions), divide el batch en líneas individuales,
parsea cada línea con regex (timestamp, hostname, program, pid, message)
y regresa un arreglo de objetos listos para que Step Functions los procese.

No escribe a DynamoDB; esa responsabilidad queda delegada a la máquina
de estados de Step Functions.

Cada item lleva `last_modified`: el LastModified del objeto en S3 (la hora
real en que llegó el batch), que es el sort key del GSI de la tabla Logs.
"""
import os
import re
import urllib.parse
from datetime import datetime, timezone

import boto3

s3 = boto3.client("s3")

# Regex para formato syslog OpenSSH:
# Dec 10 06:55:46 LabSZ sshd[24200]: Invalid user webmaster from 173.234.31.186
LOG_PATTERN = re.compile(
    r"^(?P<syslog_timestamp>[A-Za-z]{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})\s+"
    r"(?P<hostname>\S+)\s+(?P<program>[^:\[\s]+)(?:\[(?P<pid>\d+)\])?:\s?(?P<message>.*)$"
)
IP_PATTERN = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
EVENT_TYPES = [
    ("break_in_attempt", "possible break-in attempt"),
    ("invalid_user", "invalid user"),
    ("failed_password", "failed password"),
    ("auth_failure", "authentication failure"),
    ("disconnect", "received disconnect"),
]


def classify(message: str) -> str:
    """Clasifica el tipo de evento según palabras clave en el mensaje."""
    lower_msg = message.lower()
    for event_type, keyword in EVENT_TYPES:
        if keyword in lower_msg:
            return event_type
    return "other"


def build_item(line: str, batch_id: str, line_no: int, ingested_at: str, last_modified: str) -> dict | None:
    """Parsea una línea de syslog y construye el objeto de datos del evento."""
    match = LOG_PATTERN.match(line)
    if not match:
        return None

    item = match.groupdict()
    item["pid"] = item.get("pid") or ""
    item["pk"] = f"{item['hostname']}#{item['program']}"
    item["sk"] = f"{batch_id}#{line_no:05d}"
    item["event_type"] = classify(item["message"])
    item["ingested_at"] = ingested_at
    item["last_modified"] = last_modified
    item["batch_id"] = batch_id
    item["line_no"] = line_no

    ip = IP_PATTERN.search(item["message"])
    item["src_ip"] = ip.group(0) if ip else ""
    return item


def extract_bucket_and_key(event: dict) -> tuple[str, str]:
    """Extrae bucket y key del evento de forma compatible con múltiples orígenes:

    - Step Functions con payload transformado: {"bucket": "...", "key": "..."}
    - EventBridge directo (S3 Object Created detail):
      {"detail": {"bucket": {"name": "..."}, "object": {"key": "..."}}}
    - S3 direct event notification (Records).
    """
    if "bucket" in event and "key" in event:
        return event["bucket"], event["key"]

    if "detail" in event:
        detail = event["detail"]
        if "bucket" in detail and "object" in detail:
            return detail["bucket"]["name"], detail["object"]["key"]
        if "bucket" in detail and "key" in detail:
            return detail["bucket"], detail["key"]

    if "Records" in event and len(event["Records"]) > 0:
        record = event["Records"][0]
        if "s3" in record:
            return record["s3"]["bucket"]["name"], record["s3"]["object"]["key"]

    raise ValueError(f"No se pudo extraer bucket y key del evento recibido: {event}")


def lambda_handler(event, context):
    bucket, key = extract_bucket_and_key(event)
    key = urllib.parse.unquote_plus(key)
    batch_id = os.path.basename(key).removesuffix(".log")
    ingested_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    print(f"Descargando s3://{bucket}/{key}")
    response = s3.get_object(Bucket=bucket, Key=key)
    last_modified = response["LastModified"].astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    content = response["Body"].read().decode("utf-8")
    lines = content.splitlines()

    items = []
    for line_no, line in enumerate(lines, start=1):
        line = line.strip()
        if not line:
            continue
        item = build_item(line, batch_id, line_no, ingested_at, last_modified)
        if item:
            items.append(item)

    print(f"Procesadas {len(items)} líneas válidas del batch {batch_id}")
    return items
