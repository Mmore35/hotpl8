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
    def __init__(self, subscription=None, tier=None):
        self.stored = dict(subscriptionType=subscription, rateLimitTier=tier) if subscription else {}

    def account_identity(self, slot):
        return EXPECTED

    def read_account_credentials(self, slot, email):
        return json.dumps(dict(claudeAiOauth=dict(accessToken="fictional-token", refreshToken="never-use-this", **self.stored)))


def network_down(token):
    raise urllib.error.URLError("private-url")


def limited(token):
    raise urllib.error.HTTPError("private-url", 429, "secret-body", {"Retry-After": "3600"}, None)


STORED_PAIRS = (
    ("pro", "default_claude_ai", "claude-pro", "Pro"),
    ("pro", "default_claude_pro", "claude-pro", "Pro"),
    ("max", "default_claude_max_5x", "claude-max-5x", "Max"),
    ("max", "default_claude_max_20x", "claude-max-20x", "Ultra"),
)


class PlanTests(unittest.TestCase):
    def test_pro_native_rate_tiers(self):
        for tier in ("default_claude_ai", "default_claude_pro"):
            self.assertEqual(plan.classify(profile(tier=tier), EXPECTED)["profile"], "claude-pro")

    def test_max_tiers(self):
        # The tier strings and IDs are the older names; what a person reads is the current one.
        for tier, stored, label, multiplier in (("5x", "claude-max-5x", "Max", 5), ("20x", "claude-max-20x", "Ultra", None)):
            result = plan.classify(profile("claude_max", f"default_claude_max_{tier}"), EXPECTED)
            self.assertEqual((result["profile"], result["label"], result["sessionMultiplier"]), (stored, label, multiplier))

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
        self.assertEqual(result["label"], "Max or Ultra (tier unknown)")
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

    def test_the_stored_sign_in_names_the_plan_when_the_endpoint_does_not_answer(self):
        for subscription, tier, profile_id, label in STORED_PAIRS:
            for fetch in (network_down, limited):
                result = plan.read_plan(Store(subscription, tier), 1, fetch)
                said = (result["status"], result["profile"], result["label"], result["source"])
                self.assertEqual(said, ("detected", profile_id, label, "stored-sign-in"), (subscription, tier, fetch.__name__))
                # The endpoint's wait still holds, so it is not asked again before it.
                self.assertEqual(result.get("retryAfterSeconds"), 3600 if fetch is limited else None)
                serialized = json.dumps(result)
                for value in ("fictional-token", "never-use-this", EXPECTED["email"], "secret"):
                    self.assertNotIn(value, serialized)

    def test_a_stored_plan_the_table_does_not_hold_changes_nothing(self):
        for fetch, status in ((network_down, "unavailable"), (limited, "rate_limited")):
            for store in (Store(), Store("team", "default_claude_max_5x"), Store("max", "future-tier")):
                result = plan.read_plan(store, 1, fetch)
                self.assertEqual((result["status"], result["source"]), (status, "anthropic-oauth-profile"))
                self.assertNotIn("profile", result)

    def test_an_answering_endpoint_is_never_overridden(self):
        result = plan.read_plan(Store("max", "default_claude_max_20x"), 1, lambda token: profile())
        self.assertEqual((result["profile"], result["source"]), ("claude-pro", "anthropic-oauth-profile"))
        result = plan.read_plan(Store("max", "default_claude_max_20x"), 1, lambda token: profile("claude_team", "default_claude_max_5x"))
        self.assertEqual((result["status"], result["label"], result["source"]), ("partial", "Team", "anthropic-oauth-profile"))

    def test_the_plans_are_named_as_the_catalogue_names_them(self):
        catalogue = json.loads((Path(__file__).resolve().parents[1] / "data/capacity-profiles.json").read_text(encoding="utf-8"))
        claude = {key: value["tier"] for key, value in catalogue["profiles"].items() if value["provider"] == "claude"}
        self.assertEqual({key: label for key, (label, _) in plan.PLANS.items()}, claude)
        self.assertLessEqual(set(plan.ENDPOINT.values()) | set(plan.STORED.values()), set(plan.PLANS))

    def test_redirect_never_forwards_authorization(self):
        self.assertIsNone(plan.NoRedirect().redirect_request(None, None, 302, "", {}, "https://example.invalid"))


if __name__ == "__main__":
    unittest.main()
