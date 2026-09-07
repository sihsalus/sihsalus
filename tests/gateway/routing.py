#!/usr/bin/env python3
"""Exercise both gateway templates with disposable, synthetic Nginx upstreams."""

import gzip
import json
import os
from pathlib import Path
import re
import ssl
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request
import uuid


ROOT = Path(__file__).resolve().parents[2]
CONFIG = Path(os.environ.get("GATEWAY_CONFIG_DIR", ROOT / "gateway")).resolve()
IMAGE = os.environ.get("GATEWAY_TEST_IMAGE", "nginx:1.28-alpine")


def command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


class GatewayRouting(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        command("docker", "info", "--format", "{{.ServerVersion}}")
        cls.workspace = tempfile.TemporaryDirectory(prefix="sihsalus-gateway-test-")
        cls.directory = Path(cls.workspace.name)
        cls.directory.chmod(0o755)
        cls.prefix = "sihsalus-gateway-test-" + uuid.uuid4().hex[:10]
        cls.containers = []
        cls.networks = []
        cls.addClassCleanup(cls.cleanup)
        certs = cls.directory / "certs"
        certs.mkdir()
        command("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-days", "1", "-subj", "/CN=localhost", "-addext",
                "subjectAltName=DNS:localhost,IP:127.0.0.1",
                "-keyout", str(certs / "privkey.pem"),
                "-out", str(certs / "fullchain.pem"))
        command("openssl", "genpkey", "-genparam", "-algorithm", "DH",
                "-pkeyopt", "group:ffdhe2048", "-out", str(certs / "ssl-dhparams.pem"))
        (certs / "options-ssl-nginx.conf").write_text("ssl_protocols TLSv1.2 TLSv1.3;\n")
        cls.tls = ssl.create_default_context(cafile=str(certs / "fullchain.pem"))
        cls.network = cls.create_network("network")
        upstream = cls.directory / "upstream.conf"
        upstream.write_text('''server {
  listen 80;
  listen 8080;
  listen 3000;
  location = /openmrs/initialsetup { return 503 'bootstrap pending'; }
  location = /openmrs/health/started { return 503 'bootstrap pending'; }
  location = /openmrs/unavailable { return 503 'backend unavailable'; }
  location = /unavailable { return 503 'upstream unavailable'; }
  location = /gzip { default_type text/plain; return 200 'GZIP_BODY'; }
  location / {
    default_type application/json;
    return 200 '{"uri":"$request_uri","method":"$request_method","ip":"$http_x_real_ip","proto":"$http_x_forwarded_proto","host":"$http_host","upgrade":"$http_upgrade","connection":"$http_connection"}';
  }
}
'''.replace("GZIP_BODY", "x" * 2048))
        upstream_name = cls.run_container("upstream", cls.network, [
            "--network-alias", "backend", "--network-alias", "fua-generator",
            "--network-alias", "frontend", "--network-alias", "docs",
            "--network-alias", "grafana",
            "-v", f"{upstream}:/etc/nginx/conf.d/default.conf:ro",
        ])
        try:
            command("docker", "exec", upstream_name, "nginx", "-t")
        except subprocess.CalledProcessError as error:
            raise AssertionError("Invalid synthetic upstream: " +
                                 command("docker", "logs", upstream_name)) from error
        cls.urls = {}
        for scheme in ("http", "https"):
            cls.urls[scheme] = cls.start_gateway(scheme, cls.network, scheme)

    @classmethod
    def cleanup(cls):
        for name in reversed(cls.containers):
            subprocess.run(["docker", "rm", "-f", name], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=False)
        for name in reversed(cls.networks):
            subprocess.run(["docker", "network", "rm", name], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=False)
        cls.workspace.cleanup()

    @classmethod
    def create_network(cls, suffix):
        name = cls.prefix + "-" + suffix
        cls.networks.append(name)
        command("docker", "network", "create", name)
        return name

    @classmethod
    def run_container(cls, suffix, network, options):
        name = cls.prefix + "-" + suffix
        cls.containers.append(name)
        command("docker", "run", "-d", "--name", name, "--network", network,
                "--cpus", "1", "--memory", "192m", "--pids-limit", "128",
                *options, "--entrypoint", "nginx", IMAGE, "-g", "daemon off;")
        return name

    @classmethod
    def start_gateway(cls, scheme, network, suffix):
        template = "default-ssl.conf.template" if scheme == "https" else "default.conf.template"
        values = {"FRAME_ANCESTORS": "", "FUA_CONFIG": "", "FUA_LOCATIONS": "",
                  "CERT_WEB_DOMAIN_COMMON_NAME": "gateway.test",
                  "IMAGING_ACCESS_CONTROL": "deny all;",
                  "IMAGING_NETWORK_ACCESS_CONTROL": "deny all;"}
        rendered = re.sub(r"\$\{([A-Z_]+)\}", lambda match: values[match[1]],
                          (CONFIG / template).read_text())
        configuration = cls.directory / (suffix + ".conf")
        configuration.write_text(rendered)
        port = "443" if scheme == "https" else "80"
        options = [
            "-p", f"127.0.0.1::{port}",
            "-v", f"{CONFIG / 'nginx.conf'}:/etc/nginx/nginx.conf:ro",
            "-v", f"{CONFIG}:/etc/nginx/includes:ro",
            "-v", f"{configuration}:/etc/nginx/conf.d/default.conf:ro",
            "-v", f"{cls.directory / 'certs'}:/etc/letsencrypt/live/gateway.test:ro",
            "-v", f"{cls.directory / 'certs'}:/var/www/certbot/conf:ro",
        ]
        stylesheet = CONFIG / "backend-unavailable.css"
        if stylesheet.exists():
            options.extend(["-v", f"{stylesheet}:/usr/share/nginx/html/backend-unavailable.css:ro"])
        name = cls.run_container(suffix, network, options)
        try:
            address = command("docker", "port", name, port + "/tcp")
        except subprocess.CalledProcessError as error:
            raise AssertionError(error.output + command("docker", "logs", name)) from error
        url = scheme + "://" + address
        for _ in range(30):
            try:
                if cls.request(url, "/health")[0] == 200:
                    return url
            except (OSError, urllib.error.URLError):
                pass
            time.sleep(0.2)
        raise AssertionError("Gateway did not start: " + command("docker", "logs", name))

    @classmethod
    def request(cls, url, path, method="GET", headers=None):
        request = urllib.request.Request(url + path, method=method, headers=headers or {})
        try:
            response = urllib.request.urlopen(request, context=cls.tls, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.status, response.headers, response.read()

    def test_fua_preserves_path_query_and_method(self):
        for method in ("GET", "POST"):
            with self.subTest(method=method):
                status, _, body = self.request(self.urls["https"],
                    "/services/fua-generator/forms/example?format=pdf&copy=2", method)
                self.assertEqual(status, 200)
                response = json.loads(body)
                self.assertEqual(response["uri"], "/forms/example?format=pdf&copy=2")
                self.assertEqual(response["method"], method)

    def test_fua_unavailable_is_json_with_security_headers(self):
        status, headers, body = self.request(self.urls["https"],
                                             "/services/fua-generator/unavailable")
        self.assertEqual(status, 503)
        self.assertEqual(headers.get_all("Content-Type"), ["application/json"])
        self.assertEqual(json.loads(body)["status"], 503)
        self.assertEqual(headers.get("X-Content-Type-Options"), "nosniff")
        self.assertIn("max-age=", headers.get("Strict-Transport-Security", ""))

    def test_security_headers_survive_local_headers(self):
        for scheme, url in self.urls.items():
            for path, expected in (("/health", 200), ("/_sihsalus/clinical-activity", 204),
                                   ("/startup", 503), ("/ready", 503),
                                   ("/openmrs/unavailable", 503)):
                with self.subTest(scheme=scheme, path=path):
                    status, headers, body = self.request(url, path, "POST" if expected == 204 else "GET")
                    self.assertEqual(status, expected)
                    self.assertEqual(headers.get_all("X-Content-Type-Options"), ["nosniff"])
                    self.assertEqual(headers.get_all("X-Frame-Options"), ["SAMEORIGIN"])
                    self.assertTrue(headers.get("Content-Security-Policy"))
                    self.assertTrue(headers.get("Referrer-Policy"))
                    self.assertEqual(bool(headers.get("Strict-Transport-Security")), scheme == "https")
                    if expected == 204:
                        self.assertEqual(headers.get("Cache-Control"), "no-store")
                    if expected == 503:
                        self.assertEqual(headers.get("Retry-After"), "30")
                    if path == "/ready":
                        self.assertEqual(headers.get("X-SIHSALUS-Readiness"), "openmrs-bootstrap-pending")
                    if path == "/openmrs/unavailable":
                        css_path = "/_sihsalus/backend-unavailable.css"
                        self.assertIn(('href="' + css_path + '"').encode(), body)
                        self.assertNotIn(b"<style>", body)
                        css_status, css_headers, css_body = self.request(url, css_path)
                        self.assertEqual(css_status, 200)
                        self.assertEqual(css_headers.get("Content-Type"), "text/css")
                        self.assertEqual(css_body, (CONFIG / "backend-unavailable.css").read_bytes())

    def test_direct_clients_get_forwarding_defaults(self):
        for scheme, url in self.urls.items():
            with self.subTest(scheme=scheme):
                _, _, body = self.request(url, "/openmrs/probe")
                forwarded = json.loads(body)
                self.assertTrue(forwarded["ip"])
                self.assertEqual(forwarded["proto"], scheme)

    def test_http_accepts_only_known_forwarded_schemes(self):
        for supplied, expected in (("https", "https"), ("invalid", "http")):
            with self.subTest(supplied=supplied):
                _, _, body = self.request(self.urls["http"], "/openmrs/probe",
                    headers={"X-Forwarded-Proto": supplied})
                self.assertEqual(json.loads(body)["proto"], expected)

    def test_websocket_headers_and_other_prefixes(self):
        for scheme, url in self.urls.items():
            with self.subTest(scheme=scheme):
                path = "/openmrs/ws/sihsalus/notifications"
                _, _, body = self.request(url, path, headers={"Upgrade": "websocket"})
                forwarded = json.loads(body)
                self.assertEqual(forwarded["uri"], path)
                self.assertEqual(forwarded["upgrade"], "websocket")
                self.assertEqual(forwarded["connection"], "upgrade")
                self.assertEqual(forwarded["host"], url.split("://", 1)[1])
            for path, expected in (("/ayuda/guide/?page=2", "/guide/?page=2"),
                                   ("/grafana/api/health", "/grafana/api/health"),
                                   ("/openmrs/ws/sihsalus/notifications/sse", "/openmrs/ws/sihsalus/notifications/sse")):
                with self.subTest(scheme=scheme, path=path):
                    _, _, body = self.request(url, path)
                    forwarded = json.loads(body)
                    self.assertEqual(forwarded["uri"], expected)
                    self.assertEqual(forwarded["upgrade"], "")

    def test_compression_in_both_modes(self):
        for scheme, url in self.urls.items():
            with self.subTest(scheme=scheme):
                _, headers, body = self.request(url, "/openmrs/spa/gzip",
                                               headers={"Accept-Encoding": "gzip"})
                self.assertEqual(headers.get("Content-Encoding"), "gzip")
                self.assertEqual(gzip.decompress(body), b"x" * 2048)

    def test_gateway_starts_without_backend_dns(self):
        network = self.create_network("empty")
        for scheme in ("http", "https"):
            with self.subTest(scheme=scheme):
                url = self.start_gateway(scheme, network, scheme + "-empty")
                self.assertEqual(self.request(url, "/health")[0], 200)
                status, _, _ = self.request(url, "/ready")
                self.assertEqual(status, 503)


if __name__ == "__main__":
    unittest.main(verbosity=2)
