"""Log processing Lambda.

Se dispara con cada .log que llega a s3://<bucket>/input/ y guarda una
línea de log por item en la tabla de DynamoDB.

    Dec 10 06:55:46 LabSZ sshd[24200]: Invalid user webmaster from 173.234.31.186

se convierte en:

    pk = "LabSZ#sshd"                  sk = "openssh-1789440570#00007"
    event_type = "invalid_user"        src_ip = "173.234.31.186"
"""
import os
import re
import urllib.parse
from datetime import datetime, timezone

import boto3

s3 = boto3.client("s3")
table = boto3.resource("dynamodb").Table(os.environ.get("TABLE_NAME", "log-events"))

LOG_PATTERN = re.compile(
    r"^(?P<syslog_timestamp>[A-Za-z]{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})\s+"
    r"(?P<hostname>\S+)\s+(?P<program>[^:\[\s]+)(?:\[\d+\])?:\s?(?P<message>.*)$"
)
IP_PATTERN = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
EVENT_TYPES = [
    ("break_in_attempt", "possible break-in attempt"),
    ("invalid_user", "invalid user"),
    ("failed_password", "failed password"),
    ("auth_failure", "authentication failure"),
    ("disconnect", "received disconnect"),
]


def classify(message):
    message = message.lower()
    for event_type, texto in EVENT_TYPES:
        if texto in message:
            return event_type
    return "other"


def build_item(line, batch_id, line_no, ingested_at):
    match = LOG_PATTERN.match(line)
    if not match:
        return None

    item = match.groupdict()
    item["pk"] = f"{item['hostname']}#{item['program']}"
    item["sk"] = f"{batch_id}#{line_no:05d}"
    item["event_type"] = classify(item["message"])
    item["ingested_at"] = ingested_at

    ip = IP_PATTERN.search(item["message"])
    if ip:
        item["src_ip"] = ip.group(0)
    return item


def lambda_handler(event, context):
    total = 0
    for record in event.get("Records", []):
        if "s3" not in record:  # S3 manda un s3:TestEvent al crear el trigger
            continue

        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        batch_id = os.path.basename(key).removesuffix(".log")
        ingested_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        lines = s3.get_object(Bucket=bucket, Key=key)["Body"].read().decode("utf-8").splitlines()
        with table.batch_writer() as writer:
            for line_no, line in enumerate(lines, start=1):
                item = build_item(line, batch_id, line_no, ingested_at)
                if item:
                    writer.put_item(Item=item)
                    total += 1

        print(f"{key}: {total} items guardados en DynamoDB")

    return {"items": total}
