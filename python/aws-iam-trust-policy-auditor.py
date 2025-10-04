#!/usr/bin/env python3
"""
aws-iam-trust-policy-auditor.py

Purpose:
  Audit IAM role trust policies (assume role policies) for risky configurations:
  - Principal set to "*" (any AWS principal)
  - External accounts allowed (outside your allowlist)
  - Missing organization boundary (aws:PrincipalOrgID) when required
  - Missing ExternalId condition when required
  - Action wildcard in trust policy

Features:
  - Scans all IAM roles in the account
  - Filters by role name (--name-filter)
  - Allowlist account IDs (--allow-accounts) and/or require a specific org ID (--require-org-id)
  - Optionally require ExternalId condition (--require-external-id) and/or enforce a value (--external-id-value)
  - JSON output option

Safe: Read-only, no changes are made.

Permissions required:
  - iam:ListRoles, iam:GetRole

Examples:
  python aws-iam-trust-policy-auditor.py --json
  python aws-iam-trust-policy-auditor.py --allow-accounts 111111111111 222222222222 --require-external-id --json
  python aws-iam-trust-policy-auditor.py --require-org-id o-abc123 --name-filter DeployRole

Exit Codes:
  0 success
  1 unexpected error
"""
import argparse
import boto3
import json
import sys
from typing import Any, Dict, List, Optional, Tuple, Union

ActionType = Union[str, List[str]]
PrincipalType = Union[str, List[str], Dict[str, Union[str, List[str]]]]


def parse_args():
    p = argparse.ArgumentParser(description="Audit IAM role trust policies for risky settings")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--name-filter", help="Substring filter on role name")
    p.add_argument("--allow-accounts", nargs="*", help="Account IDs allowed to assume roles (in addition to self)")
    p.add_argument("--require-org-id", help="Require aws:PrincipalOrgID condition with this org id")
    p.add_argument("--require-external-id", action="store_true", help="Require sts:ExternalId condition present")
    p.add_argument("--external-id-value", help="If set, require ExternalId equals this value")
    p.add_argument("--json", action="store_true", help="JSON output")
    return p.parse_args()


def session(profile: Optional[str]):
    if profile:
        return boto3.Session(profile_name=profile)
    return boto3.Session()


def list_roles(iam):
    roles = []
    marker = None
    while True:
        kwargs = {}
        if marker:
            kwargs["Marker"] = marker
        resp = iam.list_roles(**kwargs)
        roles.extend(resp.get("Roles", []))
        if not resp.get("IsTruncated"):
            break
        marker = resp.get("Marker")
    return roles


def account_id_from_arn(arn: str) -> Optional[str]:
    # arn:partition:service:region:account-id:resource
    try:
        return arn.split(":")[4]
    except Exception:
        return None


def normalize_actions(action: ActionType) -> List[str]:
    if isinstance(action, list):
        return [str(a) for a in action]
    if action is None:
        return []
    return [str(action)]


def normalize_principals(principal: PrincipalType) -> Dict[str, List[str]]:
    # Returns dict with keys AWS, Service, Federated; values lists of strings
    norm: Dict[str, List[str]] = {"AWS": [], "Service": [], "Federated": []}
    if principal is None:
        return norm
    if isinstance(principal, str):
        # When Principal is "*"
        return {"AWS": [principal], "Service": [], "Federated": []}
    if isinstance(principal, dict):
        for k, v in principal.items():
            if isinstance(v, list):
                norm.setdefault(k, []).extend([str(x) for x in v])
            else:
                norm.setdefault(k, []).append(str(v))
        return norm
    # list not expected here for principal root
    return norm


def evaluate_trust_statement(stmt: Dict[str, Any], self_account: str, allow_accounts: List[str], require_org: Optional[str], require_ext_id: bool, ext_id_value: Optional[str]) -> List[str]:
    issues: List[str] = []
    action_list = normalize_actions(stmt.get("Action"))
    if any(a == "*" for a in action_list):
        issues.append("ACTION_WILDCARD")
    principal = normalize_principals(stmt.get("Principal"))
    # Principal "*" case
    if any(p == "*" for lst in principal.values() for p in lst):
        issues.append("ANY_PRINCIPAL_STAR")
    # AWS principals: ARNs or account ids
    aws_principals = principal.get("AWS", [])
    for p in aws_principals:
        acct = None
        if p == "*":
            continue
        if p.isdigit() and len(p) == 12:
            acct = p
        elif p.startswith("arn:"):
            acct = account_id_from_arn(p)
        if acct and acct not in set([self_account] + allow_accounts):
            issues.append(f"EXTERNAL_ACCOUNT:{acct}")
    # Conditions
    cond = stmt.get("Condition", {}) or {}
    # Normalize keys to lowercase for matching
    cond_l = {k.lower(): v for k, v in cond.items()}
    if require_org:
        key_found = any(k.endswith(":principalorgid") for k in cond_l.keys())
        if not key_found:
            issues.append("MISSING_ORG_CONDITION")
        else:
            # Value structure could be {"StringEquals": {"aws:PrincipalOrgID": "o-..."}}
            vals = []
            for v in cond_l.values():
                if isinstance(v, dict):
                    for kk, vv in v.items():
                        if isinstance(vv, (list, tuple)):
                            vals.extend([str(x) for x in vv])
                        else:
                            vals.append(str(vv))
            if require_org not in vals:
                issues.append("ORG_ID_MISMATCH")
    if require_ext_id:
        has_ext = any(k.endswith(":externalid") for k in cond_l.keys())
        if not has_ext:
            issues.append("MISSING_EXTERNAL_ID")
        elif ext_id_value is not None:
            vals = []
            for v in cond_l.values():
                if isinstance(v, dict):
                    for kk, vv in v.items():
                        if isinstance(vv, (list, tuple)):
                            vals.extend([str(x) for x in vv])
                        else:
                            vals.append(str(vv))
            if ext_id_value not in vals:
                issues.append("EXTERNAL_ID_MISMATCH")
    return issues


def main():
    args = parse_args()
    sess = session(args.profile)
    iam = sess.client("iam")
    sts = sess.client("sts")

    try:
        self_account = sts.get_caller_identity()["Account"]
    except Exception:
        # best effort
        self_account = ""

    allow_accounts = args.allow_accounts or []
    results: List[Dict[str, Any]] = []

    try:
        roles = list_roles(iam)
    except Exception as e:
        print(f"ERROR listing roles: {e}", file=sys.stderr)
        return 1

    for r in roles:
        name = r.get("RoleName")
        if args.name_filter and args.name_filter not in name:
            continue
        # AssumeRolePolicyDocument may be url-encoded JSON
        doc = r.get("AssumeRolePolicyDocument")
        if isinstance(doc, str):
            try:
                # Some SDKs provide decoded already; here try json parse
                doc = json.loads(doc)
            except Exception:
                # leave as-is
                doc = None
        if not isinstance(doc, dict):
            continue
        stmts = doc.get("Statement", [])
        if isinstance(stmts, dict):
            stmts = [stmts]
        role_issues: List[Dict[str, Any]] = []
        for idx, s in enumerate(stmts):
            issues = evaluate_trust_statement(
                s,
                self_account=self_account,
                allow_accounts=allow_accounts,
                require_org=args.require_org_id,
                require_ext_id=args.require_external_id,
                ext_id_value=args.external_id_value,
            )
            if issues:
                role_issues.append({
                    "index": idx,
                    "sid": s.get("Sid"),
                    "issues": issues,
                })
        if role_issues:
            results.append({
                "role": name,
                "arn": r.get("Arn"),
                "issues": role_issues,
            })

    if args.json:
        print(json.dumps({"findings": results}, indent=2))
        return 0

    if not results:
        print("No risky trust policy configurations detected under current rules.")
        return 0

    header = ["Role", "Issues"]
    rows = [header]
    for f in results:
        all_issues = []
        for s in f["issues"]:
            all_issues.extend(s["issues"])
        rows.append([f["role"], ",".join(all_issues)])
    widths = [max(len(str(row[i])) for row in rows) for i in range(len(header))]
    for i, row in enumerate(rows):
        line = "  ".join(str(cell).ljust(widths[j]) for j, cell in enumerate(row))
        if i == 0:
            print(line)
            print("  ".join("-" * w for w in widths))
        else:
            print(line)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("Interrupted", file=sys.stderr)
        sys.exit(130)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
