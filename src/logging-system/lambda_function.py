"""Log processing Lambda.

Triggered directly by S3 ObjectCreated events on
``s3://<bucket>/input/*.log`` (S3 -> Lambda notification). Downloads the
batch, parses each syslog-style line, and writes a CSV file with the same
base name to ``s3://<bucket>/output/*.csv``.

Expected input line format (OpenSSH / syslog style), e.g.:

    Dec 10 06:55:46 LabSZ sshd[24200]: Invalid user webmaster from 173.234.31.186

Output CSV columns:

    timestamp,hostname,program,pid,log
"""
import csv
import io
import logging
import os
import re
import urllib.parse

import boto3

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

s3 = boto3.client("s3")

INPUT_PREFIX = os.environ.get("INPUT_PREFIX", "input/")
OUTPUT_PREFIX = os.environ.get("OUTPUT_PREFIX", "output/")

CSV_HEADER = ["timestamp", "hostname", "program", "pid", "log"]

# Matches: "<timestamp> <hostname> <program>[<pid>]: <message>"
# pid and the brackets around it are optional, some daemons log without one.
LOG_PATTERN = re.compile(
    r"^(?P<timestamp>[A-Za-z]{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})\s+"
    r"(?P<hostname>\S+)\s+"
    r"(?P<program>[^:\[\s]+)"
    r"(?:\[(?P<pid>\d+)\])?"
    r":\s?(?P<log>.*)$"
)


def parse_line(line):
    """Parse a single raw log line into a CSV row dict, or None if blank."""
    line = line.rstrip("\n")
    if not line.strip():
        return None

    match = LOG_PATTERN.match(line)
    if not match:
        # Don't drop unparsable lines, keep them with empty metadata so no
        # data is lost, just flagged for a human to look at in CloudWatch.
        logger.warning("Line did not match expected pattern: %r", line)
        return {"timestamp": "", "hostname": "", "program": "", "pid": "", "log": line}

    fields = match.groupdict()
    fields["pid"] = fields["pid"] or ""
    return fields


def batch_to_csv(lines):
    """Convert a list of raw log lines into CSV text (header included)."""
    buffer = io.StringIO()
    writer = csv.DictWriter(buffer, fieldnames=CSV_HEADER)
    writer.writeheader()
    for line in lines:
        row = parse_line(line)
        if row:
            writer.writerow(row)
    return buffer.getvalue()


def output_key_for(input_key):
    """s3://.../input/<name>.log -> output/<name>.csv (same base name)."""
    filename = os.path.basename(input_key)
    base, _ext = os.path.splitext(filename)
    return f"{OUTPUT_PREFIX}{base}.csv"


def process_record(bucket, key):
    logger.info("Processing s3://%s/%s", bucket, key)

    response = s3.get_object(Bucket=bucket, Key=key)
    raw = response["Body"].read().decode("utf-8", errors="replace")
    lines = raw.splitlines()

    csv_body = batch_to_csv(lines)

    out_key = output_key_for(key)
    s3.put_object(
        Bucket=bucket,
        Key=out_key,
        Body=csv_body.encode("utf-8"),
        ContentType="text/csv",
    )
    logger.info("Wrote s3://%s/%s (%d lines)", bucket, out_key, len(lines))
    return out_key


def iter_s3_events(event):
    """Yield (bucket, key) pairs from a direct S3 event notification,
    skipping S3's own s3:TestEvent ping sent the moment a notification is
    first configured."""
    for record in event.get("Records", []):
        if record.get("Event") == "s3:TestEvent":
            logger.info("Skipping S3 test event notification.")
            continue
        if "s3" in record:
            yield record["s3"]["bucket"]["name"], record["s3"]["object"]["key"]


def lambda_handler(event, context):
    results = []
    for bucket, raw_key in iter_s3_events(event):
        key = urllib.parse.unquote_plus(raw_key)

        if not key.startswith(INPUT_PREFIX):
            logger.info("Skipping key outside of %s: %s", INPUT_PREFIX, key)
            continue

        out_key = process_record(bucket, key)
        results.append(out_key)

    return {"processed": results}
