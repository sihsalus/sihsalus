#!/usr/bin/env python3
"""Expose read-only ViewPower UPS telemetry in Prometheus format."""

from __future__ import annotations

import http.cookiejar
import json
import logging
import math
import os
import re
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


LOGGER = logging.getLogger("viewpower-exporter")
USB_DEVICE_PATTERN = re.compile(r"USB\s*\(id=([^_)\s]+)_[^)]*\)", re.IGNORECASE)


def _number(value: Any) -> float | None:
    if value in (None, ""):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def _sample(name: str, value: Any) -> str | None:
    number = _number(value)
    if number is None:
        return None
    return f"{name} {number:.15g}"


def _escape_label(value: Any) -> str:
    return str(value).replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def _warning_count(warnings: Any) -> int:
    if isinstance(warnings, (list, tuple, set, dict)):
        return len(warnings)
    return int(bool(warnings))


def _is_on_battery(mode: Any) -> int:
    normalized = str(mode or "").casefold()
    return int(any(marker in normalized for marker in ("battery", "batería", "bateria", "bat mode")))


def render_metrics(
    monitor: dict[str, Any],
    identity_response: dict[str, Any] | None,
    collected_at: float,
    scrape_duration: float,
) -> str:
    """Render one successful ViewPower sample."""

    work_info = monitor.get("workInfo")
    if not isinstance(work_info, dict):
        raise ValueError("ViewPower response does not contain workInfo")

    lines = [
        "# HELP sihsalus_ups_exporter_up Whether ViewPower returned a valid telemetry sample.",
        "# TYPE sihsalus_ups_exporter_up gauge",
        "sihsalus_ups_exporter_up 1",
        "# HELP sihsalus_ups_exporter_last_success_unixtime_seconds Unix time of the last successful ViewPower read.",
        "# TYPE sihsalus_ups_exporter_last_success_unixtime_seconds gauge",
        f"sihsalus_ups_exporter_last_success_unixtime_seconds {collected_at:.3f}",
        "# HELP sihsalus_ups_exporter_scrape_duration_seconds Time spent reading ViewPower.",
        "# TYPE sihsalus_ups_exporter_scrape_duration_seconds gauge",
        f"sihsalus_ups_exporter_scrape_duration_seconds {scrape_duration:.6f}",
    ]

    runtime_minutes = _number(work_info.get("batteryRemainTime"))
    runtime_seconds = None if runtime_minutes is None else runtime_minutes * 60
    metrics = (
        ("sihsalus_ups_battery_charge_percent", work_info.get("batteryCapacity"), "Current estimated battery charge."),
        ("sihsalus_ups_battery_runtime_seconds", runtime_seconds, "Estimated battery runtime."),
        ("sihsalus_ups_battery_voltage_volts", work_info.get("batteryVoltage"), "Current battery voltage."),
        ("sihsalus_ups_load_percent", work_info.get("outputLoadPercent"), "UPS output load as a percentage of rated capacity."),
        ("sihsalus_ups_input_voltage_volts", work_info.get("inputVoltage"), "Current utility input voltage."),
        ("sihsalus_ups_output_voltage_volts", work_info.get("outputVoltage"), "Current UPS output voltage."),
        ("sihsalus_ups_input_frequency_hertz", work_info.get("inputFrequency"), "Current utility input frequency."),
        ("sihsalus_ups_output_frequency_hertz", work_info.get("outputFrequency"), "Current UPS output frequency."),
        ("sihsalus_ups_output_current_amperes", work_info.get("outputCurrent"), "Current UPS output current."),
        ("sihsalus_ups_temperature_celsius", work_info.get("temperatureView"), "Current internal UPS temperature."),
    )
    for name, value, help_text in metrics:
        sample = _sample(name, value)
        if sample is None:
            continue
        lines.extend((f"# HELP {name} {help_text}", f"# TYPE {name} gauge", sample))

    mode = str(work_info.get("workMode") or "unknown")[:100]
    lines.extend(
        (
            "# HELP sihsalus_ups_on_battery Whether the UPS reports battery mode.",
            "# TYPE sihsalus_ups_on_battery gauge",
            f"sihsalus_ups_on_battery {_is_on_battery(mode)}",
            "# HELP sihsalus_ups_warning_count Number of warnings currently reported by ViewPower.",
            "# TYPE sihsalus_ups_warning_count gauge",
            f"sihsalus_ups_warning_count {_warning_count(work_info.get('warnings'))}",
            "# HELP sihsalus_ups_status_info Current ViewPower work mode.",
            "# TYPE sihsalus_ups_status_info gauge",
            f'sihsalus_ups_status_info{{mode="{_escape_label(mode)}"}} 1',
        )
    )

    identity = (identity_response or {}).get("identity")
    if isinstance(identity, dict):
        labels = {
            "model": str(identity.get("upsModelName") or "unknown").strip()[:100],
            "topology": str(identity.get("morphological") or "unknown").strip()[:100],
            "phase": str(identity.get("ioPhase") or "unknown").strip()[:32],
            "firmware": str(identity.get("fwVersion") or "unknown").strip()[:100],
        }
        label_text = ",".join(f'{key}="{_escape_label(value)}"' for key, value in labels.items())
        lines.extend(
            (
                "# HELP sihsalus_ups_info Static UPS identity reported by ViewPower.",
                "# TYPE sihsalus_ups_info gauge",
                f"sihsalus_ups_info{{{label_text}}} 1",
            )
        )

    return "\n".join(lines) + "\n"


class ViewPowerClient:
    def __init__(self, base_url: str, timeout: float, configured_device: str = "") -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.configured_device = configured_device
        self.device = ""
        self.identity_response: dict[str, Any] | None = None
        self._new_session()

    def _new_session(self) -> None:
        jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
        self.initialized = False
        self.device = self.configured_device
        self.identity_response = None

    def _request(self, path: str, form: dict[str, str] | None = None) -> str:
        data = urllib.parse.urlencode(form).encode() if form is not None else None
        request = urllib.request.Request(
            f"{self.base_url}/{path.lstrip('/')}",
            data=data,
            headers={"Accept": "application/json, text/plain, */*", "User-Agent": "sihsalus-viewpower-exporter/1"},
        )
        with self.opener.open(request, timeout=self.timeout) as response:
            payload = response.read(4 * 1024 * 1024 + 1)
        if len(payload) > 4 * 1024 * 1024:
            raise ValueError("ViewPower response exceeded 4 MiB")
        return payload.decode("utf-8", errors="replace").strip()

    @staticmethod
    def device_from_tree(tree: Any) -> str:
        if not isinstance(tree, list):
            raise ValueError("ViewPower device tree is not a list")
        for node in tree:
            name = str(node.get("name", "")) if isinstance(node, dict) else ""
            match = USB_DEVICE_PATTERN.search(name)
            if match:
                return f"USB{match.group(1)}"
        raise ValueError("ViewPower did not report a local USB UPS")

    def _initialize(self) -> None:
        initialized = self._request("isInitialized")
        if "SYSTEM_INITIALIZED" not in initialized:
            raise ValueError("ViewPower is not initialized")
        self._request("monitor")
        if not self.device:
            tree = json.loads(self._request("initDeviceTree", {}))
            self.device = self.device_from_tree(tree)
        self.initialized = True

    def collect(self) -> tuple[dict[str, Any], dict[str, Any] | None]:
        if not self.initialized:
            self._initialize()
        form = {"portName": self.device}
        payload = self._request("workstatus/reqMonitorData", form)
        if payload == "nologin":
            self._new_session()
            self._initialize()
            form = {"portName": self.device}
            payload = self._request("workstatus/reqMonitorData", form)
        monitor = json.loads(payload)
        if not isinstance(monitor, dict) or not isinstance(monitor.get("workInfo"), dict):
            raise ValueError("ViewPower returned invalid monitor data")
        if self.identity_response is None:
            candidate = json.loads(self._request("queryUpsInfo", form))
            if isinstance(candidate, dict):
                self.identity_response = candidate
        return monitor, self.identity_response


class MetricsCache:
    def __init__(self, client: ViewPowerClient, cache_seconds: float) -> None:
        self.client = client
        self.cache_seconds = cache_seconds
        self.expires_at = 0.0
        self.last_success = 0.0
        self.body = ""
        self.lock = threading.Lock()

    def get(self) -> str:
        now = time.time()
        if self.body and now < self.expires_at:
            return self.body
        with self.lock:
            now = time.time()
            if self.body and now < self.expires_at:
                return self.body
            started = time.monotonic()
            try:
                monitor, identity = self.client.collect()
                collected_at = time.time()
                self.last_success = collected_at
                self.body = render_metrics(monitor, identity, collected_at, time.monotonic() - started)
            except Exception as error:  # Keep the Prometheus target alive while reporting source failure.
                LOGGER.warning("ViewPower telemetry read failed: %s", error)
                duration = time.monotonic() - started
                self.body = (
                    "# HELP sihsalus_ups_exporter_up Whether ViewPower returned a valid telemetry sample.\n"
                    "# TYPE sihsalus_ups_exporter_up gauge\n"
                    "sihsalus_ups_exporter_up 0\n"
                    "# HELP sihsalus_ups_exporter_last_success_unixtime_seconds Unix time of the last successful ViewPower read.\n"
                    "# TYPE sihsalus_ups_exporter_last_success_unixtime_seconds gauge\n"
                    f"sihsalus_ups_exporter_last_success_unixtime_seconds {self.last_success:.3f}\n"
                    "# HELP sihsalus_ups_exporter_scrape_duration_seconds Time spent reading ViewPower.\n"
                    "# TYPE sihsalus_ups_exporter_scrape_duration_seconds gauge\n"
                    f"sihsalus_ups_exporter_scrape_duration_seconds {duration:.6f}\n"
                )
                self.client._new_session()
            self.expires_at = time.time() + self.cache_seconds
            return self.body


class ExporterHandler(BaseHTTPRequestHandler):
    cache: MetricsCache

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path == "/healthz":
            self._send(200, "text/plain; charset=utf-8", b"ok\n")
            return
        if self.path == "/metrics":
            self._send(200, "text/plain; version=0.0.4; charset=utf-8", self.cache.get().encode())
            return
        self._send(404, "text/plain; charset=utf-8", b"not found\n")

    def _send(self, status: int, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *_args: Any) -> None:
        return


def _positive_float(name: str, default: str) -> float:
    value = float(os.environ.get(name, default))
    if not math.isfinite(value) or value <= 0:
        raise ValueError(f"{name} must be positive")
    return value


def main() -> None:
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(message)s")
    port = int(os.environ.get("EXPORTER_PORT", "9199"))
    if not 1 <= port <= 65535:
        raise ValueError("EXPORTER_PORT must be between 1 and 65535")
    client = ViewPowerClient(
        os.environ.get("VIEWPOWER_BASE_URL", "http://host.docker.internal:15178/ViewPower"),
        _positive_float("VIEWPOWER_TIMEOUT_SECONDS", "5"),
        os.environ.get("VIEWPOWER_DEVICE", ""),
    )
    ExporterHandler.cache = MetricsCache(client, _positive_float("CACHE_SECONDS", "10"))
    server = ThreadingHTTPServer(("0.0.0.0", port), ExporterHandler)
    LOGGER.info("Listening on :%d", port)
    server.serve_forever()


if __name__ == "__main__":
    main()
