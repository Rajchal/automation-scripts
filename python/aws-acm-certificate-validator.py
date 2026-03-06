#!/usr/bin/env python3
"""
aws-acm-certificate-validator.py

Bulk validation and expiry monitor for AWS ACM certificates.
Uses AWS CLI, writes a report file, logs activity, and can send Slack/email alerts.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Tuple


LEVELS = ("INFO", "WARN", "ERROR", "CRITICAL")


def run_cmd(cmd: List[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def log_message(log_file: Path, level: str, msg: str) -> None:
    if level not in LEVELS:
        level = "INFO"
    ts = datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
    line = f"[{ts}] [{level}] {msg}"
    print(line)
    log_file.parent.mkdir(parents=True, exist_ok=True)
    with log_file.open("a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def send_slack_alert(webhook: str, message: str, severity: str) -> None:
    if not webhook:
        return
    color = "good"
    if severity == "CRITICAL":
        color = "danger"
    elif severity == "WARNING":
        color = "warning"

    payload = {
        "attachments": [
            {
                "color": color,
                "title": "ACM Certificate Alert",
                "text": message,
                "ts": int(datetime.now(tz=timezone.utc).timestamp()),
            }
        ]
    }
    run_cmd([
        "curl",
        "-s",
        "-X",
        "POST",
        "-H",
        "Content-type: application/json",
        "--data",
        json.dumps(payload),
        webhook,
    ])


def send_email_alert(email_to: str, subject: str, body: str) -> None:
    if not email_to:
        return
    if run_cmd(["sh", "-lc", "command -v mail >/dev/null 2>&1"]).returncode != 0:
        return
    run_cmd(["sh", "-lc", f"printf '%s\n' {json.dumps(body)} | mail -s {json.dumps(subject)} {json.dumps(email_to)}"])


def list_acm_certificates(region: str) -> List[str]:
    proc = run_cmd(["aws", "acm", "list-certificates", "--region", region, "--output", "json"])
    if proc.returncode != 0:
        return []
    try:
        data = json.loads(proc.stdout or "{}")
    except Exception:
        return []
    return [x.get("CertificateArn") for x in data.get("CertificateSummaryList", []) if x.get("CertificateArn")]


def describe_certificate(region: str, cert_arn: str) -> Dict[str, Any]:
    proc = run_cmd([
        "aws",
        "acm",
        "describe-certificate",
        "--certificate-arn",
        cert_arn,
        "--region",
        region,
        "--output",
        "json",
    ])
    if proc.returncode != 0:
        return {}
    try:
        return json.loads(proc.stdout or "{}")
    except Exception:
        return {}


def parse_dt(value: str) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    except Exception:
        return None


def days_until_expiry(expiry_value: str) -> int | None:
    dt_val = parse_dt(expiry_value)
    if not dt_val:
        return None
    delta = dt_val - datetime.now(timezone.utc)
    return int(delta.total_seconds() // 86400)


def write_header(output_file: Path, region: str, expiry_warn_days: int, renewal_timeout_days: int) -> None:
    output_file.parent.mkdir(parents=True, exist_ok=True)
    with output_file.open("w", encoding="utf-8") as fh:
        fh.write("AWS ACM Certificate Validation Report\n")
        fh.write("=======================================\n")
        fh.write(f"Generated: {datetime.now()}\n")
        fh.write(f"Region: {region}\n")
        fh.write(f"Expiry Warning: {expiry_warn_days} days\n")
        fh.write(f"Renewal Timeout: {renewal_timeout_days} days\n\n")


def append_lines(output_file: Path, lines: List[str]) -> None:
    with output_file.open("a", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def validate_certificates(
    output_file: Path,
    log_file: Path,
    region: str,
    expiry_warn_days: int,
    renewal_timeout_days: int,
    slack_webhook: str,
    email_to: str,
) -> int:
    _ = renewal_timeout_days
    log_message(log_file, "INFO", "Starting ACM certificate validation")

    append_lines(output_file, ["=== CERTIFICATE SUMMARY ===", ""])

    cert_arns = list_acm_certificates(region)
    if not cert_arns:
        log_message(log_file, "WARN", f"No ACM certificates found in region {region}")
        append_lines(output_file, ["Status: No certificates found", ""])
        return 0

    total_certs = 0
    expired_certs = 0
    expiring_certs = 0
    validation_failed = 0
    renewal_pending = 0
    healthy_certs = 0

    for cert_arn in cert_arns:
        total_certs += 1
        log_message(log_file, "INFO", f"Validating certificate: {cert_arn}")

        detail = describe_certificate(region, cert_arn)
        cert = detail.get("Certificate", {})

        domain_name = cert.get("DomainName") or "<unknown>"
        status = cert.get("Status") or "<unknown>"
        expiry_date = cert.get("NotAfter") or ""
        created_date = cert.get("CreatedAt") or ""
        key_algorithm = cert.get("KeyAlgorithm") or ""
        renewal_eligibility = cert.get("RenewalEligibility") or ""
        renewal_summary = (cert.get("RenewalSummary") or {}).get("Status") or ""
        validations = cert.get("DomainValidationOptions") or []

        days_to_expiry = days_until_expiry(expiry_date)

        lines = [
            "",
            f"Certificate ARN: {cert_arn}",
            f"Domain: {domain_name}",
            f"Status: {status}",
            f"Key Algorithm: {key_algorithm}",
            f"Created: {created_date}",
            f"Expires: {expiry_date}",
            f"Days Until Expiry: {days_to_expiry if days_to_expiry is not None else 'UNKNOWN'}",
            f"Renewal Eligibility: {renewal_eligibility}",
            f"Renewal Status: {renewal_summary}",
            "",
            "Domain Validations:",
        ]
        if validations:
            for item in validations:
                d = item.get("DomainName") or "<unknown>"
                st = item.get("ValidationStatus") or "<unknown>"
                lines.append(f"  - {d}: {st}")
        else:
            lines.append("  - <none>")
        lines.append("")
        append_lines(output_file, lines)

        has_issue = False
        if status != "ISSUED":
            validation_failed += 1
            has_issue = True
            msg = f"Certificate {domain_name} status is {status} (not ISSUED)"
            log_message(log_file, "WARN", msg)

        if days_to_expiry is not None and days_to_expiry < 0:
            expired_certs += 1
            has_issue = True
            msg = f"CRITICAL: Certificate {domain_name} has expired"
            log_message(log_file, "CRITICAL", msg)
            send_slack_alert(slack_webhook, msg, "CRITICAL")
            send_email_alert(email_to, "CRITICAL: ACM Certificate Expired", f"{msg}\n\nCertificate ARN: {cert_arn}")
        elif days_to_expiry is not None and days_to_expiry < expiry_warn_days:
            expiring_certs += 1
            has_issue = True
            msg = f"WARNING: Certificate {domain_name} expires in {days_to_expiry} days"
            log_message(log_file, "WARN", msg)
            send_slack_alert(slack_webhook, msg, "WARNING")

        if renewal_summary.lower() == "pending":
            renewal_pending += 1
            if not has_issue:
                has_issue = True
            log_message(log_file, "WARN", f"Certificate {domain_name} has pending renewal")

        failed_domain_validation = any((x.get("ValidationStatus") or "").lower() == "failed" for x in validations)
        if failed_domain_validation:
            validation_failed += 1
            has_issue = True
            msg = f"Certificate {domain_name} has failed domain validation"
            log_message(log_file, "ERROR", msg)
            send_slack_alert(slack_webhook, msg, "WARNING")

        if not has_issue:
            healthy_certs += 1

    append_lines(
        output_file,
        [
            "",
            "=== VALIDATION SUMMARY ===",
            f"Total Certificates: {total_certs}",
            f"Healthy: {healthy_certs}",
            f"Expiring Soon: {expiring_certs}",
            f"Expired: {expired_certs}",
            f"Validation Failed: {validation_failed}",
            f"Renewal Pending: {renewal_pending}",
            "",
        ],
    )

    issues = expired_certs + expiring_certs + validation_failed
    log_message(log_file, "INFO", f"Validation complete. Total: {total_certs}, Healthy: {healthy_certs}, Issues: {issues}")
    return issues


def list_san_certificates(output_file: Path, log_file: Path, region: str) -> None:
    log_message(log_file, "INFO", "Listing Subject Alternative Names (SANs)")
    append_lines(output_file, ["", "=== SUBJECT ALTERNATIVE NAMES (SANs) ===", ""])

    cert_arns = list_acm_certificates(region)
    for cert_arn in cert_arns:
        detail = describe_certificate(region, cert_arn)
        cert = detail.get("Certificate", {})
        domain_name = cert.get("DomainName") or "<unknown>"
        sans = cert.get("SubjectAlternativeNames") or []
        if sans:
            lines = [f"Primary Domain: {domain_name}", "SANs:"]
            lines.extend([f"  - {san}" for san in sans])
            lines.append("")
            append_lines(output_file, lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate ACM certificates for status, expiry, and domain validation")
    parser.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))
    parser.add_argument("--output-file", default=f"/tmp/acm-validator-{int(datetime.now().timestamp())}.txt")
    parser.add_argument("--log-file", default=os.environ.get("LOG_FILE", "/var/log/acm-validator.log"))
    parser.add_argument("--slack-webhook", default=os.environ.get("SLACK_WEBHOOK", ""))
    parser.add_argument("--email-to", default=os.environ.get("EMAIL_TO", ""))
    parser.add_argument("--expiry-warn-days", type=int, default=int(os.environ.get("EXPIRY_WARN_DAYS", "30")))
    parser.add_argument("--renewal-timeout-days", type=int, default=int(os.environ.get("RENEWAL_TIMEOUT_DAYS", "7")))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    output_file = Path(args.output_file)
    log_file = Path(args.log_file)

    log_message(log_file, "INFO", "=== ACM Certificate Validation Started ===")
    write_header(output_file, args.region, args.expiry_warn_days, args.renewal_timeout_days)

    validation_result = validate_certificates(
        output_file=output_file,
        log_file=log_file,
        region=args.region,
        expiry_warn_days=args.expiry_warn_days,
        renewal_timeout_days=args.renewal_timeout_days,
        slack_webhook=args.slack_webhook,
        email_to=args.email_to,
    )

    list_san_certificates(output_file, log_file, args.region)

    append_lines(output_file, ["", f"Report saved to: {output_file}", f"Log file: {log_file}"])
    print(output_file.read_text(encoding="utf-8"))
    log_message(log_file, "INFO", "=== ACM Certificate Validation Completed ===")

    return 1 if validation_result > 0 else 0


if __name__ == "__main__":
    raise SystemExit(main())
