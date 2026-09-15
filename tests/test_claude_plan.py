"""Offline contract tests: no real storage, credentials or provider requests."""
import importlib.util
import json
from pathlib import Path
import unittest
import urllib.error

spec = importlib.util.spec_from_file_location("claude_plan", Path(__file__).resolve().parents[1] / "src/providers/claude_plan.py")
plan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plan)
EXPECTED = dict(uuid="fictional-account", email="person@example.invalid", organizationUuid="fictional-org")


def profile(kind="claude_pro", tier="default_claude_ai"):
    return dict(account=dict(uuid=EXPECTED["uuid"], email=EXPECTED["email"]), organization=dict(uuid=EXPECTED["organizationUuid"], organization_type=kind, rate_limit_tier=tier))


class Store:
    def account_identity(self, slot):
        return EXPECTED

    def read_account_credentials(self, slot, email):
        return json.dumps(dict(claudeAiOauth=dict(accessToken="fictional-token", refreshToken="never-use-this")))


class PlanTests(unittest.TestCase):
    def test_pro_native_rate_tiers(self):
        for tier in ("default_claude_ai", "default_claude_pro"):
            self.assertEqual(plan.classify(profile(tier=tier), EXPECTED)["profile"], "claude-pro")

    def test_max_tiers(self):
        for multiplier in (5, 20):
            self.assertEqual(plan.classify(profile("claude_max", f"default_claude_max_{multiplier}x"), EXPECTED)["sessionMultiplier"], multiplier)

    def test_team_with_max_tier_is_not_a_consumer_max_plan(self):
        result = plan.classify(profile("claude_team", "default_claude_max_5x"), EXPECTED)
        self.assertEqual(result["label"], "Team")
        self.assertIsNone(result["profile"])

    def test_identity_and_organization_must_both_match(self):
        for object_name in ("account", "organization"):
            data = profile()
            data[object_name]["uuid"] = "different-identity"
            self.assertEqual(plan.classify(data, EXPECTED)["status"], "identity_mismatch")

    def test_uuidless_adapter_requires_email_and_org(self):
        expected = dict(EXPECTED, uuid=None)
        self.assertEqual(plan.classify(profile(), expected)["status"], "detected")
        expected["email"] = "different@example.invalid"
        self.assertEqual(plan.classify(profile(), expected)["status"], "identity_mismatch")

    def test_new_unknown_tier_does_not_get_an_invented_multiplier(self):
        result = plan.classify(profile("claude_max", "future-tier"), EXPECTED)
        self.assertEqual(result["status"], "partial")
        self.assertIsNone(result["sessionMultiplier"])

    def test_transport_projects_only_safe_fields(self):
        def fetch(token):
            self.assertEqual(token, "fictional-token")
            data = profile()
            data["private"] = "must-not-leave-helper"
            return data
        result = plan.read_plan(Store(), 1, fetch)
        self.assertEqual(result["status"], "detected")
        serialized = json.dumps(result)
        for value in ("fictional-token", "never-use-this", EXPECTED["email"], "must-not-leave-helper"):
            self.assertNotIn(value, serialized)

    def test_auth_failure_never_refreshes_or_leaks_server_body(self):
        def fetch(token):
            raise urllib.error.HTTPError("private-url", 401, "secret-body", {}, None)
        result = plan.read_plan(Store(), 1, fetch)
        self.assertEqual(result["status"], "authentication_required")
        self.assertNotIn("secret", json.dumps(result))

    def test_rate_limit_preserves_retry_after(self):
        def fetch(token):
            raise urllib.error.HTTPError("private-url", 429, "secret-body", {"Retry-After": "3600"}, None)
        result = plan.read_plan(Store(), 1, fetch)
        self.assertEqual(result["retryAfterSeconds"], 3600)

    def test_redirect_never_forwards_authorization(self):
        self.assertIsNone(plan.NoRedirect().redirect_request(None, None, 302, "", {}, "https://example.invalid"))


if __name__ == "__main__":
    unittest.main()
