"""Read subscription metadata through claude-swap; never refresh/copy tokens.

The OAuth profile endpoint is also used by claude-swap for identity checks.
Its schema is not a public stability guarantee. Unknown values stay unknown.
Only an allowlisted projection leaves this process: an identity-verified answer of the
endpoint, or, when it does not answer, the plan the stored sign-in names.
"""
import argparse
import contextlib
import hashlib
import io
import json
import logging
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor


# Each plan's ID, label and session multiplier. They are named the same in
# data/capacity-profiles.json and native/src/plans.rs; tests/test_claude_plan.py checks.
PLANS = {"claude-pro": ("Pro", 1), "claude-max-5x": ("Max", 5), "claude-max-20x": ("Ultra", None)}
# What the profile endpoint says of an organization.
ENDPOINT = {
    ("claude_pro", "default_claude_ai"): "claude-pro",
    ("claude_pro", "default_claude_pro"): "claude-pro",
    ("claude_max", "default_claude_max_5x"): "claude-max-5x",
    ("claude_max", "default_claude_max_20x"): "claude-max-20x",
}
# What Claude Code stores beside the sign-in, read when the endpoint does not answer.
STORED = {
    ("pro", "default_claude_ai"): "claude-pro",
    ("pro", "default_claude_pro"): "claude-pro",
    ("max", "default_claude_max_5x"): "claude-max-5x",
    ("max", "default_claude_max_20x"): "claude-max-20x",
}


def detected(profile):
    label, sessions = PLANS[profile]
    return dict(status="detected", profile=profile, label=label, sessionMultiplier=sessions)


def stored_plan(row, credentials):
    """The row, or the plan the stored sign-in names when the endpoint gave no answer.

    Only the two plan fields are read, and the endpoint's wait is kept."""
    if row.get("status") not in ("unavailable", "rate_limited", "authentication_required"):
        return row
    try:
        oauth = credentials.get("claudeAiOauth") or {}
        profile = STORED.get((oauth.get("subscriptionType"), oauth.get("rateLimitTier")))
    except Exception:
        return row
    return dict(row, **detected(profile), source="stored-sign-in") if profile else row


def identity_key(email, organization):
    return hashlib.sha256((email + "|" + organization).encode("utf-8")).hexdigest()


def classify(profile, expected):
    account = profile.get("account") or {}
    org = profile.get("organization") or {}
    if not isinstance(account, dict) or not isinstance(org, dict):
        return {"status": "unsupported"}
    uuid = expected.get("uuid")
    email = expected.get("email")
    org_id = expected.get("organizationUuid")
    # Require independently matching organization and account, not a slot label.
    if not org_id or org.get("uuid") != org_id:
        return {"status": "identity_mismatch"}
    if uuid:
        matches = account.get("uuid") == uuid
    else:
        matches = bool(email) and account.get("email") == email and bool(account.get("uuid"))
    if not matches:
        return {"status": "identity_mismatch"}
    kind = org.get("organization_type")
    tier = org.get("rate_limit_tier")
    match = ENDPOINT.get((kind, tier))
    if match:
        return detected(match)
    # Do not misclassify a Team organization with a Max-shaped rate tier.
    labels = {"claude_team": "Team", "claude_enterprise": "Enterprise", "claude_pro": "Pro", "claude_max": "Max or Ultra (tier unknown)"}
    if kind in labels:
        return dict(status="partial", profile=None, label=labels[kind], sessionMultiplier=None)
    return {"status": "unsupported"}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def fetch_profile(token):
    request = urllib.request.Request(
        "https://api.anthropic.com/api/oauth/profile",
        headers={"Authorization": "Bearer " + token, "User-Agent": "HotPl8/plan-metadata", "Accept": "application/json"},
    )
    with urllib.request.build_opener(NoRedirect).open(request, timeout=5) as response:
        body = response.read(262145)
        if len(body) > 262144:
            raise ValueError("response_size")
        return json.loads(body)


def read_plan(switcher, slot, fetch=fetch_profile):
    base = dict(slot=slot, source="anthropic-oauth-profile")
    credentials = {}
    try:
        expected = switcher.account_identity(str(slot))
        email = expected.get("email") or ""
        org = expected.get("organizationUuid") or ""
        base["identityKey"] = identity_key(email, org)
        raw = switcher.read_account_credentials(str(slot), email)
        credentials = json.loads(raw) if raw else {}
        token = (credentials.get("claudeAiOauth") or {}).get("accessToken")
        if not isinstance(token, str) or not token:
            return dict(base, status="no_credentials")
        profile = fetch(token)
        if not isinstance(profile, dict):
            return dict(base, status="unsupported")
        return dict(base, **classify(profile, expected))
    except urllib.error.HTTPError as error:
        retry = 900
        if error.code == 429:
            try:
                retry = max(900, min(86400, int(error.headers.get("Retry-After", "900"))))
            except (ValueError, TypeError):
                pass
        return stored_plan(dict(base, status="rate_limited" if error.code == 429 else "authentication_required" if error.code in (401, 403) else "unavailable", retryAfterSeconds=retry), credentials)
    except Exception:
        # Never stringify an exception that might carry a URL, token or body.
        return stored_plan(dict(base, status="unavailable"), credentials)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("slots", nargs="+", type=int)
    args = parser.parse_args()
    if len(args.slots) > 32 or any(not 1 <= n <= 9999 for n in args.slots):
        parser.error("invalid slot list")
    logging.disable(logging.CRITICAL)
    try:
        # cswap owns OS-specific storage and any idempotent adapter migrations.
        # Reuse its public readers instead of implementing decryption/Keychain.
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            from claude_swap.switcher import ClaudeAccountSwitcher
            switcher = ClaudeAccountSwitcher()
            with ThreadPoolExecutor(max_workers=4) as pool:
                rows = list(pool.map(lambda slot: read_plan(switcher, slot), args.slots))
        print(json.dumps(dict(schemaVersion=1, accounts=rows)))
    except Exception:
        print(json.dumps(dict(schemaVersion=1, accounts=[], status="adapter_unavailable")))


if __name__ == "__main__":
    main()
