"""Local contracts only. The real Grafana login suite is runtime.py runtime in CI."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import config
import provider
import runtime


class ProviderTests(unittest.TestCase):
    def setUp(self):
        self.now = 10
        self.fixture = provider.Fixture("synthetic-only", clock=lambda: self.now)
        self.params = {"client_id": provider.CLIENT, "redirect_uri": provider.CALLBACK,
                       "response_type": "code", "code_challenge_method": "S256", "state": "synthetic-state",
                       "scope": "openid profile email", "code_challenge": provider.b64(hashlib.sha256(b"synthetic-verifier").digest())}

    def code(self, case="viewer"):
        url = self.fixture.authorize(case, self.params)
        return provider.parse_qs(provider.urlsplit(url).query)["code"][0]

    def exchange(self, code, **changes):
        params = {"code": code, "grant_type": "authorization_code", "redirect_uri": provider.CALLBACK,
                  "code_verifier": "synthetic-verifier", **changes}
        return self.fixture.exchange(params, provider.CLIENT, "synthetic-only")

    def test_valid_exchange_is_single_use(self):
        code = self.code()
        token = self.exchange(code)
        self.assertEqual(token["token_type"], "Bearer")
        self.assertIn(token["access_token"], self.fixture.tokens)
        with self.assertRaisesRegex(ValueError, "invalid_grant"):
            self.exchange(code)

    def test_expired_code_is_denied(self):
        with self.assertRaisesRegex(ValueError, "invalid_grant"):
            self.exchange(self.code("expired_code"))

    def test_natural_code_expiry_is_denied(self):
        code = self.code()
        self.now += 61
        with self.assertRaisesRegex(ValueError, "invalid_grant"):
            self.exchange(code)

    def test_bad_pkce_is_denied(self):
        with self.assertRaisesRegex(ValueError, "invalid_grant"):
            self.exchange(self.code(), code_verifier="wrong")

    def test_missing_client_auth_is_denied(self):
        with self.assertRaisesRegex(ValueError, "invalid_client"):
            self.fixture.exchange({}, provider.CLIENT, "")

    def test_external_callback_is_denied(self):
        with self.assertRaisesRegex(ValueError, "invalid_authorization"):
            self.fixture.authorize("viewer", {**self.params, "redirect_uri": "https://example.test/callback"})

    def test_missing_pkce_is_denied(self):
        with self.assertRaisesRegex(ValueError, "invalid_authorization"):
            self.fixture.authorize("viewer", {**self.params, "code_challenge_method": "plain"})

    def test_refresh_does_not_fabricate_identity(self):
        with self.assertRaisesRegex(ValueError, "invalid_grant"):
            self.fixture.exchange({"grant_type": "refresh_token"}, provider.CLIENT, "synthetic-only")

    def test_source_fallback_fixtures_have_no_early_role(self):
        self.assertNotIn("resource_access", provider.claims("access_only", "id"))
        self.assertNotIn("resource_access", provider.claims("access_only", "userinfo"))
        self.assertEqual(provider.claims("access_only", "access")["resource_access"][provider.CLIENT]["roles"], ["grafana-admin"])
        self.assertNotIn("resource_access", provider.claims("userinfo_only", "id"))


class HarnessTests(unittest.TestCase):
    def test_runtime_docker_uses_local_socket_and_clean_environment(self):
        result = subprocess.CompletedProcess([], 0, stdout="", stderr="")
        with patch.dict(os.environ, {"DOCKER_HOST": "tcp://example.test:2375", "DOCKER_CONTEXT": "remote"}), \
                patch.object(subprocess, "run", return_value=result) as command:
            runtime.checked(["docker", "version"], "version")
        self.assertEqual(command.call_args.args[0][:3], ["docker", "--host", "unix:///var/run/docker.sock"])
        self.assertNotIn("DOCKER_HOST", command.call_args.kwargs["env"])
        self.assertNotIn("DOCKER_CONTEXT", command.call_args.kwargs["env"])

    def test_failure_evidence_only_accepts_static_codes(self):
        with self.assertRaisesRegex(runtime.Failure, "mapped_login_failed"):
            runtime.publish_evidence('{"result":"FAILED","code":"mapped_login_failed"}')
        with self.assertRaisesRegex(runtime.Failure, "invalid_test_evidence"):
            runtime.publish_evidence('{"result":"FAILED","code":"private-canary"}')

    def test_empty_evidence_does_not_pass(self):
        with self.assertRaisesRegex(runtime.Failure, "incomplete_test_evidence"):
            runtime.publish_evidence("")

    def test_container_import_does_not_require_repository_root(self):
        source = (runtime.HERE / "runtime.py").read_text()
        namespace = {"__name__": "import_probe", "__file__": "/test/runtime.py"}
        exec(compile(source, "/test/runtime.py", "exec"), namespace)
        self.assertEqual(namespace["HERE"], Path("/test"))

    def test_session_snapshot_does_not_copy_cookiejar_lock(self):
        browser = runtime.Browser()
        cookie = runtime.http.cookiejar.Cookie(0, "synthetic", "fixture-only", None, False,
            "grafana", False, False, "/", True, False, None, True, None, None, {})
        browser.cookies.set_cookie(cookie)
        snapshot = browser.snapshot_session()
        browser.cookies.clear()
        self.assertEqual(len(snapshot.cookies), 1)

    def test_redirect_allowlist(self):
        self.assertTrue(runtime.allowed_url(provider.CALLBACK))
        for url in ("https://example.test/", "http://grafana:3000.example.test/", "file:///etc/passwd",
                    "http://user:password@grafana:3000/", "http://127.0.0.1:3000/", "http://keycloak:8080@other/"):
            self.assertFalse(runtime.allowed_url(url))

    def test_no_docker_execution_outside_ephemeral_ci(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(runtime, "render") as render:
            with self.assertRaisesRegex(runtime.Failure, "ephemeral_ci_required"):
                runtime.runtime()
            render.assert_not_called()

    def test_create_is_journaled_before_command_timeout(self):
        owned = runtime.OwnedDocker()
        with patch.object(runtime, "checked", side_effect=runtime.Failure("create_timeout")):
            with self.assertRaises(runtime.Failure):
                owned.create("container", "fixture", [])
        self.assertEqual(owned.resources, [("container", owned.owner + "-fixture")])

    def test_cleanup_does_not_delete_foreign_resource(self):
        owned = runtime.OwnedDocker()
        name = owned.owner + "-fixture"
        owned.resources = [("container", name)]
        with patch.object(runtime, "checked", side_effect=[name, json.dumps([{"Config": {"Labels": {}}}])]) as command:
            with self.assertRaisesRegex(runtime.Failure, "owned_cleanup_failed"):
                owned.cleanup()
            self.assertEqual(command.call_count, 2)

    def test_cleanup_propagates_daemon_error(self):
        owned = runtime.OwnedDocker()
        owned.resources = [("network", owned.owner + "-network")]
        with patch.object(runtime, "checked", side_effect=runtime.Failure("daemon_failed")):
            with self.assertRaisesRegex(runtime.Failure, "owned_cleanup_failed"):
                owned.cleanup()

    def test_subprocess_errors_do_not_emit_captured_output(self):
        result = subprocess.CompletedProcess([], 1, stdout="private-canary", stderr="private-canary")
        with patch.object(subprocess, "run", return_value=result):
            with self.assertRaisesRegex(runtime.Failure, "fixed_operation_failed") as error:
                runtime.checked([], "fixed_operation")
            self.assertNotIn("private-canary", str(error.exception))


class ComposeTests(unittest.TestCase):
    def test_real_auditor_rejects_missing_secret_or_http_oidc(self):
        with tempfile.TemporaryDirectory(prefix="sihsalus-oidc-audit-") as directory:
            path = Path(directory) / "synthetic.env"
            command = str(runtime.repository_root() / "scripts/security/secrets_generate.sh")
            generated = subprocess.run([command, str(path)], capture_output=True)
            self.assertEqual(generated.returncode, 0)
            baseline = path.read_text().replace("DEPLOYMENT_ENV=production", "DEPLOYMENT_ENV=development")
            baseline += ("\nCOMPOSE_FILE=docker-compose.yml:compose/keycloak.yml:compose/monitoring-oidc.yml\n"
                         "COMPOSE_PROFILES=keycloak,monitoring\n"
                         "GRAFANA_ROOT_URL=https://example.test/grafana/\n"
                         "KEYCLOAK_PUBLIC_URL=https://example.test/keycloak\n")
            variants = {
                "valid": (baseline, 0, "Grafana OIDC includes monitoring"),
                "missing": ("\n".join(line for line in baseline.splitlines() if not line.startswith("GRAFANA_OIDC_CLIENT_SECRET=")) + "\n",
                            1, "GRAFANA_OIDC_CLIENT_SECRET is missing or empty"),
                "http": (baseline.replace("GRAFANA_ROOT_URL=https://", "GRAFANA_ROOT_URL=http://"),
                         1, "GRAFANA_ROOT_URL must use HTTPS"),
            }
            for case, (content, code, message) in variants.items():
                with self.subTest(case=case):
                    path.write_text(content)
                    result = subprocess.run([str(runtime.repository_root() / "scripts/security-audit.sh"), str(path)],
                        env={"PATH": os.environ["PATH"], "HOME": os.environ.get("HOME", "/tmp")},
                        capture_output=True, text=True, timeout=90)
                    self.assertEqual(result.returncode, code)
                    self.assertIn(message, result.stdout)
                    for line in content.splitlines():
                        if line.startswith(("GRAFANA_OIDC_CLIENT_SECRET=", "GRAFANA_ADMIN_PASSWORD=")):
                            self.assertNotIn(line.split("=", 1)[1], result.stdout + result.stderr)

    def test_real_rendered_override(self):
        grafana = runtime.render()
        self.assertEqual(" ".join(grafana["environment"]["GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH"].split()), config.ROLE_PATH)

    def test_no_literal_viewer_fallback(self):
        self.assertNotIn("|| 'Viewer'", config.ROLE_PATH)
        self.assertNotIn("GrafanaAdmin", config.ROLE_PATH)

    def test_secret_required_only_when_override_selected(self):
        env = {"PATH": os.environ["PATH"], "HOME": os.environ.get("HOME", "/tmp")}
        base = ["docker", "compose", "--env-file", "/dev/null", "-f", "docker-compose.yml"]
        result = subprocess.run(base + ["config", "--quiet"], cwd=runtime.repository_root(), env=env, capture_output=True)
        self.assertEqual(result.returncode, 0)
        env.update(KEYCLOAK_ADMIN_PASSWORD="synthetic", KC_DB_PASSWORD="synthetic", OAUTH2_CLIENT_SECRET="synthetic",
                   IMAGING_OIDC_CLIENT_SECRET="synthetic", GRAFANA_ROOT_URL="https://example.test/grafana/",
                   KEYCLOAK_PUBLIC_URL="https://example.test/keycloak")
        result = subprocess.run(base + ["-f", "compose/keycloak.yml", "-f", "compose/monitoring-oidc.yml", "config", "--quiet"],
                                cwd=runtime.repository_root(), env=env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"GRAFANA_OIDC_CLIENT_SECRET", result.stderr)

    def test_generator_adds_inactive_distinct_secret_with_private_permissions(self):
        with tempfile.TemporaryDirectory(prefix="sihsalus-oidc-generator-") as directory:
            path = Path(directory) / "synthetic.env"
            result = subprocess.run([str(runtime.repository_root() / "scripts/security/secrets_generate.sh"), str(path)], capture_output=True)
            self.assertEqual(result.returncode, 0)
            values = dict(line.split("=", 1) for line in path.read_text().splitlines() if line and not line.startswith("#"))
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(len(values["GRAFANA_OIDC_CLIENT_SECRET"]), 48)
            self.assertNotEqual(values["GRAFANA_OIDC_CLIENT_SECRET"], values["GRAFANA_ADMIN_PASSWORD"])
            self.assertNotIn("COMPOSE_FILE", values)
            self.assertNotIn(values["GRAFANA_OIDC_CLIENT_SECRET"].encode(), result.stdout + result.stderr)
            second = subprocess.run([str(runtime.repository_root() / "scripts/security/secrets_generate.sh"), str(path)], capture_output=True)
            self.assertNotEqual(second.returncode, 0)


if __name__ == "__main__":
    unittest.main()
