#!/usr/bin/env python3
"""
aws-iam-policy-wildcard-auditor.py

Purpose:
  Audit IAM policies (customer-managed and inline on roles/users/groups) for
  overly permissive statements that use wildcards in Action or Resource.

Flags raised per statement:
  - ACTION_WILDCARD: Effect Allow and Action contains "*" (e.g., "s3:*" or "*")
  - RESOURCE_WILDCARD: Effect Allow and Resource is "*" (global resource)

Features:
  - Scans customer-managed policies by default
  - Optionally scan inline policies on roles, users, and groups
  - Filters by policy name (--name-filter) and by service substring in action (--service-filter)
  - JSON or human-readable output
  - Read-only, safe; no modifications are made

Permissions:
  - iam:ListPolicies, iam:GetPolicy, iam:GetPolicyVersion
  - iam:ListRoles, iam:ListRolePolicies, iam:GetRolePolicy (inline)
  - iam:ListUsers, iam:ListUserPolicies, iam:GetUserPolicy (inline)
  - iam:ListGroups, iam:ListGroupPolicies, iam:GetGroupPolicy (inline)

Examples:
  python aws-iam-policy-wildcard-auditor.py --json
  python aws-iam-policy-wildcard-auditor.py --include-inline --service-filter s3

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
ResourceType = Union[str, List[str]]


def parse_args():
    p = argparse.ArgumentParser(description="Audit IAM policies for wildcard usage (read-only)")
    p.add_argument("--profile", help="AWS profile name")
    p.add_argument("--json", action="store_true", help="JSON output")
    p.add_argument("--name-filter", help="Substring filter on policy name (managed) or principal name (inline)")
    p.add_argument("--service-filter", help="Substring that must appear in Action service (e.g., s3, ec2)")
    p.add_argument("--include-inline", action="store_true", help="Scan inline policies on roles/users/groups as well")
    return p.parse_args()


def session(profile: Optional[str]):
    if profile:
        return boto3.Session(profile_name=profile)
    return boto3.Session()


# ------------- Helpers to evaluate statements -------------

def is_allow(stmt: Dict[str, Any]) -> bool:
    return stmt.get("Effect") == "Allow"


def normalize_list(val: Optional[Union[str, List[str]]]) -> List[str]:
    if val is None:
        return []
    if isinstance(val, list):
        return [str(v) for v in val]
    return [str(val)]


def action_has_service(action: str, service_filter: Optional[str]) -> bool:
    if not service_filter:
        return True
    # Action format: service:Operation or "*"
    if action == "*":
        # treat as matching all services
        return True
    parts = action.split(":", 1)
    if len(parts) == 2:
        return service_filter.lower() in parts[0].lower()
    return False


def has_action_wildcard(actions: List[str], service_filter: Optional[str]) -> bool:
    for a in actions:
        if not action_has_service(a, service_filter):
            continue
        if a == "*":
            return True
        if ":" in a:
            svc, op = a.split(":", 1)
            if op == "*":
                return True
    return False


def has_resource_wildcard(resources: List[str]) -> bool:
    for r in resources:
        if r == "*":
            return True
    return False


def evaluate_statement(stmt: Dict[str, Any], service_filter: Optional[str]) -> List[str]:
    issues: List[str] = []
    if not is_allow(stmt):
        return issues
    actions = normalize_list(stmt.get("Action"))
    resources = normalize_list(stmt.get("Resource"))
    if has_action_wildcard(actions, service_filter):
        issues.append("ACTION_WILDCARD")
    if has_resource_wildcard(resources):
        issues.append("RESOURCE_WILDCARD")
    return issues


# ------------- Managed policies -------------

def list_managed_policies(iam) -> List[Dict[str, Any]]:
    out = []
    marker = None
    while True:
        kwargs = {"Scope": "Local"}
        if marker:
            kwargs["Marker"] = marker
        resp = iam.list_policies(**kwargs)
        out.extend(resp.get("Policies", []))
        if not resp.get("IsTruncated"):
            break
        marker = resp.get("Marker")
    return out


def get_policy_doc(iam, arn: str) -> Optional[Dict[str, Any]]:
    try:
        meta = iam.get_policy(PolicyArn=arn)["Policy"]
        v = meta.get("DefaultVersionId")
        if not v:
            return None
        ver = iam.get_policy_version(PolicyArn=arn, VersionId=v)
        return json.loads(ver["PolicyVersion"]["Document"]) if isinstance(ver["PolicyVersion"]["Document"], str) else ver["PolicyVersion"]["Document"]
    except Exception:
        return None


# ------------- Inline policies -------------

def list_inline_role_policies(iam, role: str) -> List[Tuple[str, Dict[str, Any]]]:
    out = []
    marker = None
    while True:
        kwargs = {"RoleName": role}
        if marker:
            kwargs["Marker"] = marker
        resp = iam.list_role_policies(**kwargs)
        names = resp.get("PolicyNames", [])
        for n in names:
            doc = iam.get_role_policy(RoleName=role, PolicyName=n).get("PolicyDocument")
            out.append((n, doc))
        if not resp.get("IsTruncated"):
            break
        marker = resp.get("Marker")
    return out


def list_inline_user_policies(iam, user: str) -> List[Tuple[str, Dict[str, Any]]]:
    out = []
    marker = None
    while True:
        kwargs = {"UserName": user}
        if marker:
            kwargs["Marker"] = marker
        resp = iam.list_user_policies(**kwargs)
        names = resp.get("PolicyNames", [])
        for n in names:
            doc = iam.get_user_policy(UserName=user, PolicyName=n).get("PolicyDocument")
            out.append((n, doc))
        if not resp.get("IsTruncated"):
            break
        marker = resp.get("Marker")
    return out


def list_inline_group_policies(iam, group: str) -> List[Tuple[str, Dict[str, Any]]]:
    out = []
    marker = None
    while True:
        kwargs = {"GroupName": group}
        if marker:
            kwargs["Marker"] = marker
        resp = iam.list_group_policies(**kwargs)
        names = resp.get("PolicyNames", [])
        for n in names:
            doc = iam.get_group_policy(GroupName=group, PolicyName=n).get("PolicyDocument")
            out.append((n, doc))
        if not resp.get("IsTruncated"):
            break
        marker = resp.get("Marker")
    return out


def list_all_roles(iam) -> List[str]:
    out = []
    marker = None
    while True:
        kwargs = {}
        if marker:
            kwargs["Marker"] = marker
        resp = iam.list_roles(**kwargs)
        out.extend([r.get("RoleName") for r in resp.get("Roles", [])])
        if not resp.get("IsTruncated"):
            break
        marker = resp.get("Marker")
    return out


def list_all_users(iam) -> List[str]:
    out = []
    marker = None
    while True:
        kwargs = {}
        if marker:
            kwargs["Marker"] = marker
        resp = iam.list_users(**kwargs)
        out.extend([u.get("UserName") for u in resp.get("Users", [])])
        if not resp.get("IsTruncated"):
            break
        marker = resp.get("Marker")
    return out


def list_all_groups(iam) -> List[str]:
    out = []
    marker = None
    while True:
        kwargs = {}
        if marker:
            kwargs["Marker"] = marker
        resp = iam.list_groups(**kwargs)
        out.extend([g.get("GroupName") for g in resp.get("Groups", [])])
        if not resp.get("IsTruncated"):
            break
        marker = resp.get("Marker")
    return out


# ------------- Main -------------

def eval_doc(doc: Dict[str, Any], service_filter: Optional[str]) -> List[Dict[str, Any]]:
    results: List[Dict[str, Any]] = []
    if not doc:
        return results
    stmts = doc.get("Statement", [])
    if isinstance(stmts, dict):
        stmts = [stmts]
    for idx, s in enumerate(stmts):
        issues = evaluate_statement(s, service_filter)
        if issues:
            results.append({
                "index": idx,
                "sid": s.get("Sid"),
                "issues": issues,
                "action": s.get("Action"),
                "resource": s.get("Resource"),
            })
    return results


def main():
    args = parse_args()
    sess = session(args.profile)
    iam = sess.client("iam")

    findings: List[Dict[str, Any]] = []

    # Managed policies
    try:
        policies = list_managed_policies(iam)
    except Exception as e:
        print(f"ERROR listing policies: {e}", file=sys.stderr)
        return 1
    for p in policies:
        name = p.get("PolicyName")
        if args.name_filter and args.name_filter not in name:
            continue
        doc = get_policy_doc(iam, p.get("Arn"))
        stmt_issues = eval_doc(doc, args.service_filter)
        if not stmt_issues:
            continue
        findings.append({
            "type": "managed",
            "name": name,
            "arn": p.get("Arn"),
            "issues": stmt_issues,
        })

    # Inline policies
    if args.include_inline:
        # Roles
        try:
            roles = list_all_roles(iam)
            for r in roles:
                if args.name_filter and args.name_filter not in r:
                    continue
                for pol_name, doc in list_inline_role_policies(iam, r):
                    stmt_issues = eval_doc(doc, args.service_filter)
                    if stmt_issues:
                        findings.append({
                            "type": "inline-role",
                            "principal": r,
                            "policy": pol_name,
                            "issues": stmt_issues,
                        })
        except Exception:
            pass
        # Users
        try:
            users = list_all_users(iam)
            for u in users:
                if args.name_filter and args.name_filter not in u:
                    continue
                for pol_name, doc in list_inline_user_policies(iam, u):
                    stmt_issues = eval_doc(doc, args.service_filter)
                    if stmt_issues:
                        findings.append({
                            "type": "inline-user",
                            "principal": u,
                            "policy": pol_name,
                            "issues": stmt_issues,
                        })
        except Exception:
            pass
        # Groups
        try:
            groups = list_all_groups(iam)
            for g in groups:
                if args.name_filter and args.name_filter not in g:
                    continue
                for pol_name, doc in list_inline_group_policies(iam, g):
                    stmt_issues = eval_doc(doc, args.service_filter)
                    if stmt_issues:
                        findings.append({
                            "type": "inline-group",
                            "principal": g,
                            "policy": pol_name,
                            "issues": stmt_issues,
                        })
        except Exception:
            pass

    if args.json:
        print(json.dumps({"findings": findings}, indent=2))
        return 0

    if not findings:
        print("No wildcard issues detected in scanned IAM policies.")
        return 0

    header = ["Type", "Name/Principal", "Policy/Arn", "Issues"]
    rows = [header]
    for f in findings:
        if f["type"] == "managed":
            rows.append([f["type"], f["name"], f.get("arn"), "; ".join(
                [",".join(i["issues"]) for i in f["issues"]]
            )])
        else:
            rows.append([f["type"], f.get("principal"), f.get("policy"), "; ".join(
                [",".join(i["issues"]) for i in f["issues"]]
            )])
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
