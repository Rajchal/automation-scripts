#!/usr/bin/env python3
"""
aws-acm-certificate-auditor.py

Audit AWS ACM certificates for upcoming expiration and validation issues.
Generates a report file, logs to /var/log/aws-acm-certificate-auditor.log, and optionally sends Slack alerts.
"""
import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import List, Dict, Any

LOG_FILE = Path("/var/log/aws-acm-certificate-auditor.log")

def log(msg: str) -> None:
    ts = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    line = f"[{ts}] {msg}"
    print(line)
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with LOG_FILE.open("a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def run_aws(cmd: List[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def send_slack(webhook: str, text: str) -> None:
    if not webhook:
        return
    payload = json.dumps({"text": text})
    subprocess.run(
        ["curl", "-s", "-X", "POST", "-H", "Content-type: application/json", "--data", payload, webhook],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def iso_to_dt(s: str):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc)
    except Exception:
        return None


def days_until(dt_obj: datetime) -> int:
    delta = dt_obj - datetime.now(timezone.utc)
    return int(delta.total_seconds() // 86400)


def list_cert_arns(region: str, max_results: int) -> List[str]:
    cmd = ["aws", "acm", "list-certificates", "--region", region, "--max-items", str(max_results), "--output", "json"]
    proc = run_aws(cmd)
    if proc.returncode != 0:
        log(f"list-certificates failed: {proc.stdout.strip()}")
        return []
    try:
        data = json.loads(proc.stdout or "{}")
        return [c.get("CertificateArn") for c in data.get("CertificateSummaryList", []) if c.get("CertificateArn")]
    except Exception as e:
        log(f"Failed to parse list-certificates output: {e}")
        return []


def describe_cert(region: str, arn: str) -> Dict[str, Any]:
    cmd = ["aws", "acm", "describe-certificate", "--certificate-arn", arn, "--region", region, "--output", "json"]
    proc = run_aws(cmd)
    if proc.returncode != 0:
        log(f"describe-certificate failed for {arn}: {proc.stdout.strip()}")
        return {}
    try:
        return json.loads(proc.stdout or "{}")
    except Exception:
        return {}


def write_report_header(report_path: Path, region: str, expiry_days: int) -> None:
    ts = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    with report_path.open("w", encoding="utf-8") as fh:
        fh.write(f"ACM Certificate Auditor - {ts}\n")
        fh.write(f"Region: {region}\n")
        fh.write(f"Expiry threshold (days): {expiry_days}\n\n")


def audit(region: str, expiry_days: int, max_results: int, webhook: str) -> Path:
    report_path = Path(f"/tmp/acm-certificate-auditor-{datetime.utcnow().strftime('%Y%m%d%H%M%S')}.txt")
    write_report_header(report_path, region, expiry_days)

    arns = list_cert_arns(region, max_results)
    if not arns:
        with report_path.open("a", encoding="utf-8") as fh:
            fh.write("No ACM certificates found.\n")
        log(f"No ACM certificates in region {region}")
        return report_path

    now = datetime.now(timezone.utc)
    warn_after = now + timedelta(days=expiry_days)
    total = 0
    expiring = 0

    for arn in arns:
        total += 1
        detail = describe_cert(region, arn)
        cert = detail.get("Certificate", {})
        domain = cert.get("DomainName", "<unknown>")
        status = cert.get("Status", "<unknown>")
        not_after_str = cert.get("NotAfter") or ""
        not_before = cert.get("NotBefore") or ""
        validation_opts = cert.get("DomainValidationOptions", [])
        cert_type = cert.get("Type", "<unknown>")

        not_after_dt = iso_to_dt(not_after_str) if not_after_str else None
        days_left = days_until(not_after_dt) if not_after_dt else None

        lines = [
            f"Certificate: {arn}",
            f"Domain: {domain}",
            f"Type: {cert_type}",
            f"Status: {status}",
            f"NotBefore: {not_before}",
            f"NotAfter: {not_after_str} ({days_left} days)" if days_left is not None else f"NotAfter: {not_after_str}",
            "DomainValidationOptions:",
        ]
        for opt in validation_opts:
            dname = opt.get("DomainName", "<unknown>")
            vstatus = opt.get("ValidationStatus", "<unknown>")
            method = opt.get("ValidationMethod", "<unknown>")
            lines.append(f" - DomainName: {dname} status={vstatus} method={method}")
        lines.append("")

        with report_path.open("a", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")

        if not_after_dt and not_after_dt <= warn_after:
            expiring += 1
            msg = f"ACM Alert: Certificate for {domain} ({arn}) expires in {days_left} days (status={status})."
            send_slack(webhook, msg)

        for opt in validation_opts:
            vstatus = opt.get("ValidationStatus") or "<unknown>"
            if vstatus != "SUCCESS":
                msg = f"ACM Alert: Certificate {arn} domain {opt.get('DomainName','<unknown>')} validation status={vstatus}"
                send_slack(webhook, msg)

        if status in {"EXPIRED", "INACTIVE"}:
            send_slack(webhook, f"ACM Alert: Certificate {arn} has status {status} for domain {domain}")

    with report_path.open("a", encoding="utf-8") as fh:
        fh.write(f"Summary: total={total}, expiring_soon={expiring}\n")
    log(f"ACM auditor written to {report_path} (total={total}, expiring_soon={expiring})")
    return report_path


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit ACM certificates for expiry and validation issues")
    parser.add_argument("--region", default=os.environ.get("AWS_REGION") or os.environ.get("REGION") or "us-east-1")
    parser.add_argument("--expiry-days", type=int, default=int(os.environ.get("ACM_EXPIRY_DAYS", 30)))
    parser.add_argument("--max-results", type=int, default=int(os.environ.get("ACM_MAX_RESULTS", 200)))
    parser.add_argument("--slack-webhook", default=os.environ.get("SLACK_WEBHOOK", ""))
    args = parser.parse_args()

    audit(args.region, args.expiry_days, args.max_results, args.slack_webhook)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
