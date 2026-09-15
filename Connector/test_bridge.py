"""Credential-free tests for data meaning, partial failures and the stdio boundary."""
import io
import json
import os
import subprocess
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

import bridge


class NormalizationTests(unittest.TestCase):
    def test_missing_and_sentinel_are_not_zero(self):
        metrics = {}
        bridge.normalize_stats({"totalSteps": 0, "restingHeartRate": 0,
                                "averageStressLevel": -1, "totalDistanceMeters": None}, metrics)
        self.assertEqual(metrics, {"steps": {"value": 0}})
        for value in [None, True, False, "51", float("nan"), float("inf"), -1]:
            bridge.put(metrics, "vo2Max", value)
        self.assertNotIn("vo2Max", metrics)

    def test_units_and_garmin_intensity_credit(self):
        metrics = {}
        bridge.normalize_stats({"totalDistanceMeters": 5600, "moderateIntensityMinutes": 20,
                                "vigorousIntensityMinutes": 12}, metrics)
        bridge.normalize_sleep({"dailySleepDTO": {"sleepTimeSeconds": 27720,
                               "sleepScores": {"overall": {"value": 87}}}}, metrics)
        bridge.normalize_weight({"dateWeightList": [{"weight": 76400}]}, metrics)
        self.assertEqual(metrics["distance"]["value"], 5.6)
        self.assertEqual(metrics["intensityMinutes"]["value"], 44)
        self.assertEqual(metrics["sleepDuration"]["value"], 462)
        self.assertEqual(metrics["weight"]["value"], 76.4)
        self.assertNotIn("measuredAt", metrics["sleepDuration"])

    def test_missing_intensity_operand_does_not_assume_zero(self):
        metrics = {}
        bridge.normalize_stats({"moderateIntensityMinutes": 20}, metrics)
        self.assertNotIn("intensityMinutes", metrics)

    def test_latest_real_sample_ignores_trailing_sentinel_and_order(self):
        metrics = {}
        bridge.normalize_heart({"heartRateValues": [[1789430520000, None], [1789430400000, 62],
                               [1789430460000, 64], [1789430600000, -1]]}, metrics)
        self.assertEqual(metrics["heartRate"]["value"], 64)
        self.assertEqual(metrics["heartRate"]["measuredAt"], bridge.timestamp(1789430460000))

    def test_battery_reads_level_not_charged_or_drained(self):
        metrics = {}
        bridge.normalize_battery([{"charged": 93, "drained": 42, "bodyBatteryValuesArray":
                                  [[1789430400000, 68], [1789430460000, 65], [1789430520000, None]]}], metrics)
        self.assertEqual(metrics["bodyBattery"]["value"], 65)

    def test_timestamps_do_not_assign_a_zone_to_unknown_fields(self):
        self.assertIsNone(bridge.timestamp("2026-09-15T08:00:00"))
        self.assertEqual(bridge.timestamp("2026-09-15T08:00:00", known_utc=True), "2026-09-15T08:00:00Z")
        self.assertEqual(bridge.timestamp("2026-09-15T08:00:00+03:00"), "2026-09-15T05:00:00Z")
        self.assertIsNone(bridge.timestamp(1789430400))
        self.assertIsNone(bridge.timestamp("2026-09-15"))

    def test_readiness_uses_latest_and_explicit_recovery_zero(self):
        metrics = {}
        bridge.normalize_readiness([
            {"timestamp": "2026-09-15T09:00:00", "score": 82, "recoveryTime": 480,
             "recoveryTimeChangePhrase": "REACHED_ZERO"},
            {"timestamp": "2026-09-15T06:00:00", "score": 69, "recoveryTime": 660},
        ], metrics)
        self.assertEqual(metrics["trainingReadiness"]["value"], 82)
        self.assertEqual(metrics["recoveryTime"]["value"], 0)
        self.assertEqual(metrics["recoveryTime"]["measuredAt"], "2026-09-15T09:00:00Z")

    def test_training_load_selects_primary_watch(self):
        metrics = {}
        bridge.normalize_training({"mostRecentTrainingStatus": {"latestTrainingStatusData": {
            "older-watch": {"acuteTrainingLoadDTO": {"dailyTrainingLoadAcute": 123}},
            "primary-watch": {"primaryTrainingDevice": True,
                              "acuteTrainingLoadDTO": {"dailyTrainingLoadAcute": 583}},
        }}}, metrics)
        self.assertEqual(metrics["trainingLoad"]["value"], 583)

    def test_unknown_response_shapes_are_empty_not_recursive_guesses(self):
        for _, _, normalizer in bridge.ENDPOINTS:
            for data in [None, [], "bad", {"unknown": {"score": 99}}, ["bad", 99]]:
                metrics = {}
                normalizer(data, metrics)
                self.assertEqual(metrics, {})


def fake_api():
    api = Mock()
    for _, method, _ in bridge.ENDPOINTS:
        getattr(api, method).return_value = {}
    api.get_stats.return_value = {"totalSteps": 1234}
    api.get_devices.return_value = [{"displayName": "fēnix 8", "deviceId": "never-return-this"}]
    api.connectapi.return_value = {"displayName": "synthetic-profile", "fullName": "never-return-name"}
    api.client.dumps.return_value = json.dumps({"di_token": "synthetic-access", "di_refresh_token": "synthetic-refresh"})
    return api


class FetchTests(unittest.TestCase):
    def test_optional_endpoint_failure_preserves_other_metrics(self):
        api = fake_api()
        api.get_hrv_data.side_effect = RuntimeError("contains private response")
        snapshot = bridge.fetch_snapshot(api, source_date="2026-09-15")
        self.assertEqual(snapshot["metrics"]["steps"]["value"], 1234)
        self.assertEqual(snapshot["warnings"], ["unavailable.hrv"])
        self.assertEqual(snapshot["devices"], ["fēnix 8"])
        self.assertNotIn("private", json.dumps(snapshot))
        self.assertFalse(snapshot["isDemo"])

    def test_rate_limit_stops_subsequent_requests(self):
        api = fake_api()
        api.get_heart_rates.side_effect = bridge.BridgeError("rate_limit")
        with self.assertRaises(bridge.BridgeError) as caught:
            bridge.fetch_snapshot(api)
        self.assertEqual(caught.exception.code, "rate_limit")
        api.get_body_battery.assert_not_called()
        api.get_devices.assert_not_called()

    def test_global_network_failure_does_not_report_success(self):
        api = fake_api()
        for _, method, _ in bridge.ENDPOINTS:
            getattr(api, method).side_effect = ConnectionError("sensitive host details")
        with self.assertRaises(bridge.BridgeError) as caught:
            bridge.fetch_snapshot(api)
        self.assertEqual(caught.exception.code, "network")

    def test_process_deadline_bypasses_optional_failure_handling(self):
        api = fake_api()
        api.get_stats.side_effect = bridge.DeadlineExpired()
        with self.assertRaises(bridge.DeadlineExpired):
            bridge.fetch_snapshot(api)
        api.get_heart_rates.assert_not_called()


class ProtocolTests(unittest.TestCase):
    def test_mfa_event_and_session_return_without_persisting(self):
        api = fake_api()
        api.client.login.side_effect = lambda email, password, prompt_mfa: self.assertEqual(prompt_mfa(), "123456")
        events = []
        request = {"command": "login", "email": "synthetic@example.invalid", "password": "synthetic-secret"}
        with patch("builtins.open", side_effect=AssertionError("No files may be opened")):
            result = bridge.execute(request, events.append, io.StringIO('{"mfa":"123456"}\n'), api_factory=lambda cn: api)
        self.assertEqual(events[0], {"event": "mfa_required"})
        self.assertEqual(events[1]["event"], "session")
        self.assertEqual(events[1]["session"], result["session"])
        self.assertEqual(result["event"], "result")
        self.assertNotIn("password", request)
        self.assertNotIn("email", request)
        self.assertNotIn("synthetic-secret", json.dumps(result))
        self.assertNotIn("never-return-name", json.dumps(result))
        api.client.dump.assert_not_called()
        api.client.load.assert_not_called()

    def test_sync_restores_inline_session_and_returns_rotated_session(self):
        api = fake_api()
        session = json.dumps({"version": 1, "isChina": True, "tokens": {"di_token": "old-access"}})
        factory = Mock(return_value=api)
        result = bridge.execute({"command": "sync", "session": session}, lambda _: None,
                                io.StringIO(), api_factory=factory)
        factory.assert_called_once_with(True)
        self.assertEqual(json.loads(api.client.loads.call_args.args[0]), {"di_token": "old-access"})
        self.assertEqual(json.loads(result["session"])["tokens"]["di_token"], "synthetic-access")
        api.client.login.assert_not_called()

    def test_path_cannot_be_interpreted_as_token_file(self):
        factory = Mock()
        with self.assertRaises(bridge.BridgeError):
            bridge.execute({"command": "sync", "session": "/some/token/file"}, lambda _: None,
                           io.StringIO(), api_factory=factory)
        factory.assert_not_called()

    def test_error_output_never_contains_exception_body(self):
        output = io.StringIO()
        with patch.object(bridge, "execute", side_effect=RuntimeError("secret-password token=user-data")):
            status = bridge.run(io.StringIO('{"command":"login"}\n'), output)
        self.assertEqual(status, 1)
        event = json.loads(output.getvalue())
        self.assertEqual(event["code"], "unknown")
        self.assertNotIn("secret", output.getvalue())

    def test_deadline_returns_a_single_safe_error(self):
        output = io.StringIO()
        with patch.object(bridge, "execute", side_effect=bridge.DeadlineExpired()):
            status = bridge.run(io.StringIO('{"command":"sync"}\n'), output)
        self.assertEqual(status, 1)
        self.assertEqual(json.loads(output.getvalue())["code"], "network")
        self.assertEqual(len(output.getvalue().splitlines()), 1)

    def test_demo_cli_without_environment_or_dependency_import(self):
        completed = subprocess.run([sys.executable, "-I", os.path.abspath(bridge.__file__)],
                                   input='{"command":"demo"}\n', capture_output=True,
                                   text=True, env={}, timeout=10)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stderr, "")
        event = json.loads(completed.stdout)
        self.assertTrue(event["snapshot"]["isDemo"])
        self.assertEqual(len(event["snapshot"]["metrics"]), 26)
        self.assertNotIn("session", event)

    def test_installed_client_configuration_never_uses_file_token_store(self):
        api = bridge.make_api(False)
        self.assertEqual(api.retry_attempts, 0)
        self.assertIsNone(api.client._tokenstore_path)
        self.assertIn("mobile+requests", api.client.skip_strategies)


class SingleAttemptAuthenticationTests(unittest.TestCase):
    """Exercise the real pinned client's flow with fake network transports."""

    def test_first_http_429_stops_before_tls_rotation(self):
        from garminconnect import client as upstream
        api = bridge.make_api(False)
        response = SimpleNamespace(status_code=429, json=lambda: {})
        session = SimpleNamespace(post=Mock(return_value=response))
        with patch.object(upstream.cffi_requests, "Session", return_value=session) as constructor:
            with self.assertRaises(bridge.AuthFlowStopped) as caught:
                api.client.login("synthetic@example.invalid", "synthetic-password")
        self.assertEqual(caught.exception.code, "rate_limit")
        self.assertEqual(session.post.call_count, 1)
        constructor.assert_called_once_with(impersonate=upstream.MOBILE_IMPERSONATIONS[0])

    def test_http_403_is_not_reclassified_as_rate_limit_or_retried(self):
        from garminconnect import client as upstream
        api = bridge.make_api(False)
        response = SimpleNamespace(status_code=403, json=lambda: {})
        session = SimpleNamespace(post=Mock(return_value=response))
        with patch.object(upstream.cffi_requests, "Session", return_value=session) as constructor:
            with self.assertRaises(Exception) as caught:
                api.client.login("synthetic@example.invalid", "synthetic-password")
        self.assertEqual(bridge.error_code(caught.exception), "network")
        self.assertEqual(session.post.call_count, 1)
        self.assertEqual(constructor.call_count, 1)

    def test_json_429_is_preserved_without_http_429(self):
        from garminconnect import client as upstream
        api = bridge.make_api(False)
        response = SimpleNamespace(status_code=200, json=lambda: {"error": {"status-code": "429"}})
        session = SimpleNamespace(post=Mock(return_value=response))
        with patch.object(upstream.cffi_requests, "Session", return_value=session):
            with self.assertRaises(bridge.AuthFlowStopped) as caught:
                api.client.login("synthetic@example.invalid", "synthetic-password")
        self.assertEqual(caught.exception.code, "rate_limit")
        self.assertEqual(session.post.call_count, 1)

    def test_mfa_429_stops_before_alternate_endpoint(self):
        from garminconnect import client as upstream
        api = bridge.make_api(False)
        session = SimpleNamespace(post=Mock(side_effect=[
            SimpleNamespace(status_code=200, json=lambda: {"responseStatus": {"type": "MFA_REQUIRED"}}),
            SimpleNamespace(status_code=429, json=lambda: {}),
        ]))
        with patch.object(upstream.cffi_requests, "Session", return_value=session):
            with self.assertRaises(bridge.AuthFlowStopped) as caught:
                api.client.login("synthetic@example.invalid", "synthetic-password", prompt_mfa=lambda: "123456")
        self.assertEqual(caught.exception.code, "rate_limit")
        self.assertEqual(session.post.call_count, 2)  # One login plus one verification.
        self.assertTrue(session.post.call_args.args[0].endswith("/mobile/api/mfa/verifyCode"))

    def test_rejected_mfa_is_not_resubmitted_to_alternate_endpoint(self):
        from garminconnect import client as upstream
        api = bridge.make_api(False)
        session = SimpleNamespace(post=Mock(side_effect=[
            SimpleNamespace(status_code=200, json=lambda: {"responseStatus": {"type": "MFA_REQUIRED"}}),
            SimpleNamespace(status_code=200, json=lambda: {"responseStatus": {"type": "INVALID_CODE"}}),
        ]))
        with patch.object(upstream.cffi_requests, "Session", return_value=session):
            with self.assertRaises(bridge.AuthFlowStopped) as caught:
                api.client.login("synthetic@example.invalid", "synthetic-password", prompt_mfa=lambda: "123456")
        self.assertEqual(caught.exception.code, "auth")
        self.assertEqual(session.post.call_count, 2)

    def test_di_exchange_429_stops_before_token_or_cookie_fallback(self):
        from garminconnect import client as upstream
        api = bridge.make_api(False)
        api.client.cs = Mock()
        response = SimpleNamespace(status_code=429, json=lambda: {})
        with patch.object(upstream.cffi_requests, "post", return_value=response) as post:
            with self.assertRaises(bridge.AuthFlowStopped) as caught:
                api.client._establish_session("synthetic-ticket")
        self.assertEqual(caught.exception.code, "rate_limit")
        self.assertEqual(post.call_count, 1)
        api.client.cs.get.assert_not_called()

    def test_guard_stops_at_protocol_boundary_with_safe_error(self):
        output = io.StringIO()
        with patch.object(bridge, "execute", side_effect=bridge.AuthFlowStopped("rate_limit")):
            status = bridge.run(io.StringIO('{"command":"login"}\n'), output)
        self.assertEqual(status, 1)
        event = json.loads(output.getvalue())
        self.assertEqual(event["code"], "rate_limit")
        self.assertEqual(len(output.getvalue().splitlines()), 1)


class DiagnosticAndCheckpointTests(unittest.TestCase):
    def test_rate_limit_takes_priority_when_challenge_header_is_also_present(self):
        events = []
        response = SimpleNamespace(status_code=429, headers={"cf-mitigated": "challenge", "retry-after": "3600"}, json=lambda: {})
        session = bridge.GuardedSession(SimpleNamespace(get=Mock(return_value=response)), bridge.DiagnosticTrace(events.append))
        with self.assertRaises(bridge.AuthFlowStopped) as caught:
            session.get("https://sso.garmin.com/mobile/api/login")
        self.assertEqual(caught.exception.code, "rate_limit")
        self.assertEqual(events[-1]["diagnostic"]["retryAfterSeconds"], 3600)

    def test_diagnostic_never_exposes_urls_bodies_headers_or_identity(self):
        events = []
        trace = bridge.DiagnosticTrace(events.append)
        trace.stage = "profile"
        response = SimpleNamespace(status_code=429, headers={
            "content-type": "application/json", "retry-after": "7200",
            "set-cookie": "private-cookie", "authorization": "private-token"
        }, json=lambda: {"email": "private-email", "error": {"status-code": "429", "message": "private-password"}})
        trace.response(response, "https://connectapi.garmin.com/profile/private-id?ticket=private-ticket")
        value = events[0]["diagnostic"]
        self.assertEqual(value["stage"], "profile")
        self.assertEqual(value["httpStatus"], 429)
        self.assertEqual(value["apiErrorStatus"], 429)
        self.assertEqual(value["retryAfterSeconds"], 7200)
        self.assertNotIn("private", json.dumps(events))
        self.assertNotIn("garmin.com", json.dumps(events))

    def test_security_challenge_is_distinct_from_bad_password(self):
        events = []
        trace = bridge.DiagnosticTrace(events.append)
        response = SimpleNamespace(status_code=403, headers={"cf-mitigated": "challenge", "content-type": "text/html"}, json=lambda: {})
        with self.assertRaises(bridge.AuthFlowStopped) as caught:
            trace.response(response)
        self.assertEqual(caught.exception.code, "security_challenge")
        self.assertTrue(events[0]["diagnostic"]["challenge"])

    def test_successful_auth_session_is_emitted_before_later_rate_limit(self):
        api = fake_api()
        api.get_heart_rates.side_effect = bridge.AuthFlowStopped("rate_limit")
        events = []
        with self.assertRaises(bridge.AuthFlowStopped):
            bridge.execute({"command": "login", "email": "synthetic@example.invalid", "password": "synthetic-secret"},
                           events.append, io.StringIO(), api_factory=lambda _: api)
        self.assertEqual([event["event"] for event in events], ["session"])
        self.assertEqual(json.loads(events[0]["session"])["tokens"]["di_token"], "synthetic-access")
        api.get_body_battery.assert_not_called()

    def test_rotated_token_is_checkpointed_even_when_request_fails(self):
        api = fake_api()
        def fail_after_rotation(*args):
            api.client.dumps.return_value = json.dumps({"di_token": "rotated-access", "di_refresh_token": "rotated-refresh"})
            raise bridge.AuthFlowStopped("rate_limit")
        api.get_stats.side_effect = fail_after_rotation
        events = []
        with self.assertRaises(bridge.AuthFlowStopped):
            bridge.execute({"command": "login", "email": "synthetic@example.invalid", "password": "synthetic-secret"},
                           events.append, io.StringIO(), api_factory=lambda _: api)
        self.assertEqual(len(events), 2)
        self.assertEqual(json.loads(events[-1]["session"])["tokens"]["di_refresh_token"], "rotated-refresh")

    def test_nonrestorable_cookie_session_is_not_reported_as_bad_password(self):
        api = fake_api()
        api.client.dumps.return_value = json.dumps({"di_token": None})
        events = []
        with self.assertRaises(bridge.BridgeError) as caught:
            bridge.execute({"command": "login", "email": "synthetic@example.invalid", "password": "synthetic-secret"},
                           events.append, io.StringIO(), api_factory=lambda _: api)
        self.assertEqual(caught.exception.code, "session_unsupported")
        self.assertEqual(events, [])
        api.connectapi.assert_not_called()

    def test_final_rejection_is_classified_after_refresh_is_exhausted(self):
        for status, expected in [(401, "auth"), (403, "access_denied")]:
            def fail(request, emit, stdin, *, trace):
                trace.response(SimpleNamespace(status_code=status, headers={}, json=lambda: {}))
                raise ConnectionError("private response")
            output = io.StringIO()
            with patch.object(bridge, "execute", side_effect=fail):
                self.assertEqual(bridge.run(io.StringIO('{"command":"sync"}\n'), output), 1)
            events = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual(events[-1]["code"], expected)
            self.assertNotIn("private", output.getvalue())


if __name__ == "__main__":
    unittest.main()
