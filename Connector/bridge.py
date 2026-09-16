#!/usr/bin/env python3
"""Read-only Garmin bridge. One command per process; JSON lines over stdio.

The process never persists credentials, sessions, or health data. Its caller
owns Keychain storage and the local snapshot cache. See docs/connector-protocol.md.
"""
from __future__ import annotations

import contextlib
import io
import json
import logging
import math
import re
import signal
import sys
from datetime import date, datetime, timezone
from email.utils import parsedate_to_datetime
from typing import Any, Callable, TextIO
from urllib.parse import urlsplit

VERSION = 1
MAX_INPUT = 131072
NETWORK_BUDGET = 180
MFA_BUDGET = 180
ERROR_MESSAGES = {
    "auth": "Garmin sign-in is required. Check your credentials and verification code.",
    "rate_limit": "Garmin has limited requests. Please wait before trying again.",
    "network": "Could not reach Garmin. Check your connection and try again later.",
    "dependency": "The Garmin connector is unavailable. Rebuild or reinstall the application.",
    "unknown": "The Garmin request could not be completed.",
    "access_denied": "Garmin denied access to this request; the saved session has been retained.",
    "security_challenge": "Garmin requires an interactive security check.",
    "session_unsupported": "Garmin returned a session that this connector cannot safely restore.",
}


class DiagnosticTrace:
    """Allowlisted response metadata only. Never URLs, headers, bodies or identity."""

    def __init__(self, emit: Callable[[dict], None]):
        self.emit = emit
        self.stage = "starting"
        self.request_count = 0
        self.last: dict = {}

    def response(self, response: Any, url: str = "") -> Any:
        self.request_count += 1
        path = urlsplit(url).path if isinstance(url, str) else ""
        stage = self.stage
        if path.endswith("/login"): stage = "login"
        elif path.endswith("/mfa/verifyCode"): stage = "mfa"
        elif path.endswith("/token"):
            host = urlsplit(url).hostname or ""
            stage = "di_token" if host.startswith("diauth.") else ("it_token" if host.startswith("services.") else "token_exchange")
        detail: dict = {"stage": stage, "requestCount": self.request_count}
        status = getattr(response, "status_code", None)
        if isinstance(status, int) and not isinstance(status, bool) and 100 <= status <= 599:
            detail["httpStatus"] = status
        headers = getattr(response, "headers", {})
        def header(name: str) -> str:
            value = headers.get(name, "") if hasattr(headers, "get") else ""
            return value if isinstance(value, str) else ""
        content_type = header("content-type").lower()
        detail["responseKind"] = "json" if "json" in content_type else ("html" if "html" in content_type else "other")
        detail["challenge"] = header("cf-mitigated").lower() == "challenge"
        retry_after = header("retry-after")
        try:
            seconds = int(retry_after) if retry_after.isdigit() else int((parsedate_to_datetime(retry_after) - datetime.now(timezone.utc)).total_seconds())
            if 0 <= seconds <= 604800: detail["retryAfterSeconds"] = seconds
        except (TypeError, ValueError, OverflowError):
            pass
        try:
            error_status = mapping(mapping(response.json()).get("error")).get("status-code")
            if isinstance(error_status, str) and error_status.isdigit(): error_status = int(error_status)
            if isinstance(error_status, int) and not isinstance(error_status, bool) and 100 <= error_status <= 599:
                detail["apiErrorStatus"] = error_status
        except Exception:
            pass
        self.last = detail
        self.emit({"event": "diagnostic", "diagnostic": detail})
        if detail["challenge"] and status != 429 and detail.get("apiErrorStatus") != 429:
            raise AuthFlowStopped("security_challenge")
        return response


class BridgeError(Exception):
    def __init__(self, code: str):
        self.code = code
        super().__init__(ERROR_MESSAGES[code])


class DeadlineExpired(BaseException):
    """Bypass dependency retry handlers when the whole process budget expires."""


class AuthFlowStopped(BaseException):
    """Stop upstream fallback handlers without another authentication request."""

    def __init__(self, code: str):
        self.code = code
        super().__init__(ERROR_MESSAGES[code])


def guard_rate_limit(response: Any) -> Any:
    """Preserve Garmin's first 429 even when a dependency would try a fallback."""
    if getattr(response, "status_code", None) == 429:
        raise AuthFlowStopped("rate_limit")
    try:
        payload = response.json()
    except Exception:
        return response
    code = mapping(mapping(payload).get("error")).get("status-code")
    if code in (429, "429"):
        raise AuthFlowStopped("rate_limit")
    return response


class GuardedSession:
    """Per-client transport proxy; does not change TLS, headers, or destinations."""

    def __init__(self, session: Any, trace: DiagnosticTrace | None = None):
        self.session = session
        self.mfa_submitted = False
        self.trace = trace

    def checked(self, response: Any, url: str = "") -> Any:
        if self.trace: self.trace.response(response, url)
        return guard_rate_limit(response)

    def __getattr__(self, name: str) -> Any:
        return getattr(self.session, name)

    def request(self, *args: Any, **kwargs: Any) -> Any:
        url = args[1] if len(args) > 1 else kwargs.get("url", "")
        return self.checked(self.session.request(*args, **kwargs), url)

    def get(self, *args: Any, **kwargs: Any) -> Any:
        return self.checked(self.session.get(*args, **kwargs), args[0] if args else kwargs.get("url", ""))

    def post(self, url: str, **kwargs: Any) -> Any:
        if url.endswith("/api/mfa/verifyCode"):
            # The pinned client's MFA handler otherwise submits the same code
            # to a second endpoint after an unsuccessful first verification.
            if self.mfa_submitted:
                raise AuthFlowStopped("auth")
            self.mfa_submitted = True
        return self.checked(self.session.post(url, **kwargs), url)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def number(value: Any, *, positive: bool = False) -> float | int | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        finite = math.isfinite(value)
    except OverflowError:
        return None
    if not finite or value < 0 or (positive and value == 0):
        return None
    return value


def mapping(value: Any) -> dict:
    return value if isinstance(value, dict) else {}


def records(value: Any) -> list[dict]:
    return [item for item in value if isinstance(item, dict)] if isinstance(value, list) else []


def timestamp(value: Any, *, known_utc: bool = False) -> str | None:
    """Epoch arrays are milliseconds; a timezone-free string needs a GMT field."""
    try:
        if number(value, positive=True) is not None:
            # Reject seconds/relative timestamps rather than invent a date.
            if value < 946684800000:
                return None
            dt = datetime.fromtimestamp(value / 1000, timezone.utc)
        elif isinstance(value, str) and "T" in value:
            dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
            if dt.tzinfo is None:
                if not known_utc:
                    return None
                dt = dt.replace(tzinfo=timezone.utc)
        else:
            return None
        return dt.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    except (ValueError, OverflowError, OSError):
        return None


def put(metrics: dict, key: str, value: Any, *, scale: float = 1,
        measured_at: str | None = None, positive: bool = False,
        maximum: float | None = None) -> None:
    value = number(value, positive=positive)
    if value is None or (maximum is not None and value > maximum):
        return
    converted = value * scale
    if not math.isfinite(converted):
        return
    metric = {"value": round(converted, 4)}
    if measured_at:
        metric["measuredAt"] = measured_at
    metrics[key] = metric


def latest_pair(rows: Any, *, value_index: int = 1, maximum: float | None = None,
                positive: bool = False) -> tuple[Any, str | None]:
    best: tuple[str, Any] | None = None
    for row in rows if isinstance(rows, list) else []:
        if not isinstance(row, list) or len(row) <= value_index:
            continue
        measured_at = timestamp(row[0])
        value = number(row[value_index], positive=positive)
        if measured_at and value is not None and (maximum is None or value <= maximum):
            if best is None or measured_at > best[0]:
                best = measured_at, value
    return (best[1], best[0]) if best else (None, None)


def normalize_stats(data: Any, metrics: dict) -> None:
    data = mapping(data)
    fields = {
        "steps": "totalSteps", "stepGoal": "dailyStepGoal",
        "calories": "totalKilocalories", "activeCalories": "activeKilocalories",
        "floors": "floorsAscended", "restingHeartRate": "restingHeartRate",
    }
    for key, field in fields.items():
        put(metrics, key, data.get(field), positive=key in {"stepGoal", "restingHeartRate"})
    put(metrics, "distance", data.get("totalDistanceMeters"), scale=0.001)
    put(metrics, "stress", data.get("averageStressLevel"), maximum=100)
    moderate = number(data.get("moderateIntensityMinutes"))
    vigorous = number(data.get("vigorousIntensityMinutes"))
    # Garmin credits vigorous minutes twice. Require both rather than assume 0.
    if moderate is not None and vigorous is not None:
        put(metrics, "intensityMinutes", moderate + vigorous * 2)


def normalize_heart(data: Any, metrics: dict) -> None:
    data = mapping(data)
    value, measured_at = latest_pair(data.get("heartRateValues"), positive=True)
    put(metrics, "heartRate", value, measured_at=measured_at, positive=True)
    put(metrics, "restingHeartRate", data.get("restingHeartRate"), positive=True)


def normalize_battery(data: Any, metrics: dict) -> None:
    candidates = []
    for entry in records(data):
        value, measured_at = latest_pair(entry.get("bodyBatteryValuesArray"), maximum=100)
        if measured_at:
            candidates.append((measured_at, value))
    if candidates:
        measured_at, value = max(candidates)
        put(metrics, "bodyBattery", value, measured_at=measured_at, maximum=100)


def normalize_sleep(data: Any, metrics: dict) -> None:
    data = mapping(mapping(data).get("dailySleepDTO"))
    measured_at = timestamp(data.get("sleepEndTimestampGMT"), known_utc=True)
    for key, field in {
        "sleepDuration": "sleepTimeSeconds", "deepSleep": "deepSleepSeconds",
        "lightSleep": "lightSleepSeconds", "remSleep": "remSleepSeconds",
        "awakeSleep": "awakeSleepSeconds",
    }.items():
        put(metrics, key, data.get(field), scale=1 / 60, measured_at=measured_at)
    overall = mapping(mapping(data.get("sleepScores")).get("overall"))
    put(metrics, "sleepScore", overall.get("value"), measured_at=measured_at, maximum=100)


def normalize_hrv(data: Any, metrics: dict) -> None:
    data = mapping(data)
    value = mapping(data.get("hrvSummary")).get("lastNightAvg")
    measured_at = timestamp(data.get("sleepEndTimestampGMT"), known_utc=True)
    put(metrics, "hrv", value, positive=True, measured_at=measured_at)


def normalize_spo2(data: Any, metrics: dict) -> None:
    put(metrics, "spo2", mapping(data).get("averageSpO2"), positive=True, maximum=100)


def normalize_respiration(data: Any, metrics: dict) -> None:
    # The metric is explicitly labelled sleeping respiration in the native UI.
    put(metrics, "respiration", mapping(data).get("avgSleepRespirationValue"), positive=True)


def normalize_readiness(data: Any, metrics: dict) -> None:
    entries = records(data)
    if not entries:
        return
    # timestamp is UTC, distinct from timestampLocal in the source DTO.
    dated = [(timestamp(entry.get("timestamp"), known_utc=True), entry) for entry in entries]
    known = [(t, entry) for t, entry in dated if t]
    if known:
        measured_at, selected = max(known, key=lambda pair: pair[0])
    elif len(entries) == 1:
        measured_at, selected = None, entries[0]
    else:
        return  # Multiple undated snapshots have no reliable ordering.
    put(metrics, "trainingReadiness", selected.get("score"), maximum=100, measured_at=measured_at)
    recovery = 0 if selected.get("recoveryTimeChangePhrase") == "REACHED_ZERO" else selected.get("recoveryTime")
    put(metrics, "recoveryTime", recovery, measured_at=measured_at)


def normalize_hydration(data: Any, metrics: dict) -> None:
    put(metrics, "hydration", mapping(data).get("valueInML"))


def normalize_weight(data: Any, metrics: dict) -> None:
    entries = records(mapping(data).get("dateWeightList"))
    dated = [(timestamp(e.get("timestampGMT"), known_utc=True), e) for e in entries]
    known = [(t, e) for t, e in dated if t and number(e.get("weight"), positive=True) is not None]
    if known:
        measured_at, entry = max(known, key=lambda pair: pair[0])
    elif len(entries) == 1:
        measured_at, entry = None, entries[0]
    else:
        return
    # The weight service reports grams, independently of the UI's unitKey.
    put(metrics, "weight", entry.get("weight"), scale=0.001, positive=True, measured_at=measured_at)


def normalize_max_metrics(data: Any, metrics: dict) -> None:
    entries = records(data)
    if not entries and isinstance(data, dict):
        entries = [data]
    generic = [mapping(entry.get("generic")) for entry in entries]
    generic = [entry for entry in generic if entry]
    if not generic:
        return
    entry = max(generic, key=lambda e: str(e.get("calendarDate", "")))
    value = entry.get("vo2MaxPreciseValue")
    if number(value, positive=True) is None:
        value = entry.get("vo2MaxValue")
    put(metrics, "vo2Max", value, positive=True)


def normalize_training(data: Any, metrics: dict) -> None:
    latest = mapping(mapping(data).get("mostRecentTrainingStatus"))
    device_map = mapping(latest.get("latestTrainingStatusData"))
    entries = [e for e in device_map.values() if isinstance(e, dict)]
    primary = [e for e in entries if e.get("primaryTrainingDevice") is True]
    if primary:
        entries = primary
    if len(entries) != 1:
        return  # Never combine load across watches or arbitrarily pick a device.
    load = mapping(entries[0].get("acuteTrainingLoadDTO"))
    put(metrics, "trainingLoad", load.get("dailyTrainingLoadAcute"))


ENDPOINTS = (
    ("stats", "get_stats", normalize_stats),
    ("heart", "get_heart_rates", normalize_heart),
    ("body_battery", "get_body_battery", normalize_battery),
    ("sleep", "get_sleep_data", normalize_sleep),
    ("hrv", "get_hrv_data", normalize_hrv),
    ("spo2", "get_spo2_data", normalize_spo2),
    ("respiration", "get_respiration_data", normalize_respiration),
    ("readiness", "get_training_readiness", normalize_readiness),
    ("vo2_max", "get_max_metrics", normalize_max_metrics),
    ("training", "get_training_status", normalize_training),
    ("weight", "get_daily_weigh_ins", normalize_weight),
    ("hydration", "get_hydration_data", normalize_hydration),
)


def error_code(error: Exception) -> str:
    if isinstance(error, BridgeError):
        return error.code
    if isinstance(error, (ImportError, ModuleNotFoundError)):
        return "dependency"
    names = {cls.__name__ for cls in type(error).__mro__}
    if "GarminConnectTooManyRequestsError" in names:
        return "rate_limit"
    if "GarminConnectAuthenticationError" in names:
        return "auth"
    status = getattr(getattr(error, "response", None), "status_code", None)
    if status == 429:
        return "rate_limit"
    if status == 401:
        return "auth"
    if status == 403:
        return "access_denied"
    if names & {"GarminConnectConnectionError", "ConnectionError", "Timeout", "TimeoutError"}:
        return "network"
    return "unknown"


def fetch_snapshot(api: Any, *, source_date: str | None = None,
                   checkpoint: Callable[[], None] | None = None,
                   trace: DiagnosticTrace | None = None) -> dict:
    source_date = source_date or date.today().isoformat()
    metrics: dict = {}
    warnings: list[str] = []
    successes = 0
    failures: list[str] = []
    for group, method, normalizer in ENDPOINTS:
        if trace: trace.stage = group
        try:
            data = getattr(api, method)(source_date)
            normalizer(data, metrics)
            successes += 1
        except Exception as error:
            code = error_code(error)
            if code in {"auth", "rate_limit"}:
                raise BridgeError(code) from None
            failures.append(code)
            warnings.append(f"unavailable.{group}")
        finally:
            if checkpoint: checkpoint()
    devices = []
    if trace: trace.stage = "devices"
    try:
        for entry in records(api.get_devices()):
            name = entry.get("displayName")
            if isinstance(name, str) and name.strip():
                devices.append(name.strip()[:120])
    except Exception as error:
        code = error_code(error)
        if code in {"auth", "rate_limit"}:
            raise BridgeError(code) from None
        warnings.append("unavailable.devices")
    finally:
        if checkpoint: checkpoint()
    if successes == 0 and failures:
        raise BridgeError("network" if "network" in failures else "unknown")
    if not metrics:
        warnings.append("no_data")
    return {"fetchedAt": utc_now(), "sourceDate": source_date, "isDemo": False,
            "devices": list(dict.fromkeys(devices)), "metrics": metrics, "warnings": warnings}


def demo_snapshot() -> dict:
    values = {
        "steps": 7248, "stepGoal": 10000, "distance": 5.6, "calories": 1870,
        "activeCalories": 436, "floors": 12, "intensityMinutes": 48,
        "restingHeartRate": 49, "heartRate": 64, "stress": 27, "bodyBattery": 76,
        "sleepDuration": 462, "sleepScore": 87, "deepSleep": 84, "remSleep": 106,
        "lightSleep": 272, "awakeSleep": 18, "hrv": 62, "spo2": 98,
        "respiration": 14, "trainingReadiness": 82, "recoveryTime": 960,
        "vo2Max": 51, "trainingLoad": 583, "weight": 76.4, "hydration": 1650,
    }
    return {"fetchedAt": utc_now(), "sourceDate": date.today().isoformat(), "isDemo": True,
            "devices": ["Garmin fēnix 8 · Demo"],
            "metrics": {key: {"value": value} for key, value in values.items()}, "warnings": []}


def read_message(stream: TextIO) -> dict:
    line = stream.readline(MAX_INPUT + 1)
    if not line or len(line) > MAX_INPUT:
        raise BridgeError("unknown")
    try:
        value = json.loads(line)
    except (ValueError, TypeError):
        raise BridgeError("unknown") from None
    if not isinstance(value, dict):
        raise BridgeError("unknown")
    return value


def unpack_session(session: Any) -> tuple[bool, str]:
    try:
        if not isinstance(session, str) or len(session) > MAX_INPUT:
            raise ValueError
        envelope = json.loads(session)
        if envelope.get("version") != VERSION or not isinstance(envelope.get("isChina"), bool):
            raise ValueError
        tokens = envelope["tokens"]
        if not isinstance(tokens, dict) or not isinstance(tokens.get("di_token"), str) or not tokens["di_token"]:
            raise ValueError
        return envelope["isChina"], json.dumps(tokens)
    except (ValueError, TypeError, AttributeError, KeyError):
        raise BridgeError("auth") from None


def make_api(is_china: bool, trace: DiagnosticTrace | None = None) -> Any:
    from garminconnect import Garmin
    from garminconnect import client as garmin_client
    # No Garmin.login(): it consults GARMINTOKENS and retries profile requests.
    # Direct client.login()/loads()/dumps() keeps every token exclusively in RAM.
    api = Garmin(is_cn=is_china, retry_attempts=0, verify_login=False)
    api.client.skip_strategies = {
        "mobile+requests", "widget+cffi", "portal+cffi", "portal+requests"
    }
    client = api.client
    # 0.3.15 exposes no constructor option to disable the inner mobile TLS
    # rotation. Use its existing first/default profile exactly once. The
    # private API is version-pinned and covered by transport-level mock tests.
    def login_once(email: str, password: str) -> None:
        if not garmin_client.HAS_CFFI or not garmin_client.MOBILE_IMPERSONATIONS:
            raise BridgeError("dependency")
        session = garmin_client.cffi_requests.Session(
            impersonate=garmin_client.MOBILE_IMPERSONATIONS[0]
        )
        client._do_mobile_login(GuardedSession(session, trace), email, password)

    client._mobile_login_cffi = login_once
    client._api_session = GuardedSession(client._api_session, trace)
    client.cs = GuardedSession(client.cs, trace)
    original_post = client._http_post

    def post_once(*args: Any, **kwargs: Any) -> Any:
        # DI ticket exchange/refresh must not fall through to another token
        # client ID or JWT authentication after a rate-limited response.
        response = original_post(*args, **kwargs)
        if trace: trace.response(response, args[0] if args else kwargs.get("url", ""))
        return guard_rate_limit(response)

    client._http_post = post_once
    return api


def execute(request: dict, emit: Callable[[dict], None], stdin: TextIO,
            *, api_factory: Callable[[bool], Any] = make_api,
            trace: DiagnosticTrace | None = None) -> dict:
    command = request.get("command")
    if command == "demo":
        return {"event": "result", "snapshot": demo_snapshot()}
    if command == "diagnose":
        # Offline release smoke test: constructing the client loads the TLS
        # extension and CA bundle but never starts authentication or a request.
        from importlib import metadata
        import certifi
        from pathlib import Path
        api_factory(False)
        if not Path(certifi.where()).is_file():
            raise BridgeError("dependency")
        return {"event": "diagnostics", "ok": True,
                "connectorVersion": VERSION, "garminconnect": metadata.version("garminconnect")}
    if command == "sync":
        is_china, token_json = unpack_session(request.get("session"))
    elif command == "login":
        is_china = request.get("isChina", False)
        if not isinstance(is_china, bool):
            raise BridgeError("auth")
        if not all(isinstance(request.get(key), str) and request[key].strip() for key in ("email", "password")):
            raise BridgeError("auth")
    else:
        raise BridgeError("unknown")
    trace = trace or DiagnosticTrace(emit)
    api = make_api(is_china, trace) if api_factory is make_api else api_factory(is_china)
    last_session: str | None = None

    def checkpoint() -> None:
        nonlocal last_session
        try:
            tokens = json.loads(api.client.dumps())
        except (ValueError, TypeError, AttributeError):
            return
        if not isinstance(tokens, dict) or not isinstance(tokens.get("di_token"), str) or not tokens["di_token"]:
            # A JWT_WEB-only upstream fallback cannot be reconstructed from dumps().
            return
        serialized = json.dumps({"version": VERSION, "isChina": is_china, "tokens": tokens}, separators=(",", ":"))
        if serialized != last_session:
            emit({"event": "session", "session": serialized})
            last_session = serialized

    def prompt_mfa() -> str:
        # Restore the network deadline after time spent waiting for the user.
        remaining = signal.alarm(0) if hasattr(signal, "SIGALRM") else 0
        if remaining:
            signal.alarm(MFA_BUDGET)
        try:
            emit({"event": "mfa_required"})
            code = read_message(stdin).get("mfa")
            if not isinstance(code, str) or not re.fullmatch(r"[0-9]{4,10}", code.strip()):
                raise BridgeError("auth")
            return code.strip()
        finally:
            if remaining:
                signal.alarm(remaining)

    if command == "login":
        trace.stage = "login"
        # Discard the request's credential references as soon as login finishes.
        try:
            api.client.login(request["email"].strip(), request["password"], prompt_mfa=prompt_mfa)
        finally:
            request.pop("email", None)
            request.pop("password", None)
    else:
        trace.stage = "restore_session"
        api.client.loads(token_json)
    checkpoint()
    if last_session is None:
        raise BridgeError("session_unsupported")
    # A single profile read both verifies authentication and supplies the encoded
    # display name required by daily summary/sleep/heart endpoints.
    trace.stage = "profile"
    try:
        profile = api.connectapi("/userprofile-service/socialProfile")
    finally:
        checkpoint()
    display_name = mapping(profile).get("displayName")
    if not isinstance(display_name, str) or not display_name.strip():
        raise BridgeError("auth")
    api.display_name = display_name
    snapshot = fetch_snapshot(api, checkpoint=checkpoint, trace=trace)
    return {"event": "result", "session": last_session, "snapshot": snapshot}


def run(stdin: TextIO = sys.stdin, stdout: TextIO = sys.stdout) -> int:
    def emit(value: dict) -> None:
        stdout.write(json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n")
        stdout.flush()

    # Third-party exception logs may include profile IDs or HTTP bodies. The
    # protocol carries only a stable error code and a deliberately generic text.
    logging.disable(logging.CRITICAL)
    trace = DiagnosticTrace(emit)
    try:
        request = read_message(stdin)
        # Swallow accidental dependency prints, but keep our explicit protocol
        # writer outside the redirection. Nothing is mirrored into stderr.
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            result = execute(request, emit, stdin, trace=trace)
        emit(result)
        return 0
    except DeadlineExpired:
        emit({"event": "error", "code": "network", "message": ERROR_MESSAGES["network"]})
        return 1
    except AuthFlowStopped as error:
        emit({"event": "error", "code": error.code, "message": ERROR_MESSAGES[error.code]})
        return 1
    except Exception as error:
        code = error_code(error)
        # Classify the final API rejection after the pinned client's own token
        # refresh has finished; never mistake a rejected token for bad Wi-Fi.
        if code == "network" and trace.last.get("httpStatus") == 401:
            code = "auth"
        elif code == "network" and trace.last.get("httpStatus") == 403:
            code = "access_denied"
        emit({"event": "error", "code": code, "message": ERROR_MESSAGES[code]})
        return 1


def main() -> int:
    if hasattr(signal, "SIGALRM"):
        def timed_out(_signum: int, _frame: Any) -> None:
            raise DeadlineExpired()
        signal.signal(signal.SIGALRM, timed_out)
        signal.alarm(NETWORK_BUDGET)
    return run()


if __name__ == "__main__":
    sys.exit(main())
