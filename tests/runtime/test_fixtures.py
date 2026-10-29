"""Guard actual Compose selections and redact exclusively synthetic test secrets."""

from copy import deepcopy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import quote

import fixtures


ROOT = Path(__file__).resolve().parents[2]
DIGEST = "sha256:" + "a" * 64
FRONTEND_SOURCE_IMAGE = ("ghcr.io/sihsalus/sihsalus-frontend:sha-b956aba619e4e651e7d942e3f95eb88f607803e5"
                         "@sha256:089d96130cca872d9b08f7e55e8ef354daf7ee77e19b72f8b28db8a4522bc1c2")


class RuntimeFixtureTests(unittest.TestCase):
    def test_audit_database_failure_cannot_pass_healthy_core_or_reach_browser(self):
        cases = {
            "valid": ("1\n1\n1\n1\n", 0),
            "binlog-or-trust-invalid": ("0\n1\n1\n1\n", 0),
            "global-privileges": ("1\n0\n1\n1\n", 0),
            "missing-or-wrong-trigger": ("1\n1\n0\n1\n", 0),
            "missing-validation": ("1\n1\n1\n0\n", 0),
            "database-error": ("", 42),
            "unexpected-output": ("1\n1\n1\n1\n1\n", 0),
        }
        for name, (checks, sql_exit) in cases.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                temporary = Path(directory)
                state = temporary / "state"
                fixture, model = self.render(state, "local")
                repository = temporary / "repository"
                runtime = repository / "tests/runtime"
                runtime.mkdir(parents=True)
                for script in ("run.sh", "fixtures.py"):
                    shutil.copyfile(ROOT / "tests/runtime" / script, runtime / script)
                for service in model["services"].values():
                    for mount in service.get("volumes", []):
                        if mount["type"] == "bind":
                            mount["source"] = str(repository / Path(mount["source"]).relative_to(ROOT))
                (temporary / "model.json").write_text(json.dumps(model))
                commands = temporary / "bin"
                commands.mkdir()
                docker = commands / "docker"
                docker.write_text("#!/usr/bin/env python3\n" + '''import json, os, pathlib, sys
args = sys.argv[1:]
if args == ['context', 'show']: print('default')
elif args[0] == 'info': print('synthetic-version')
elif args[0] == 'compose':
    if 'config' in args: print(pathlib.Path(os.environ['AUDIT_TEST_MODEL']).read_text())
    elif 'exec' in args:
        command = args[-1]
        if '--user="$MYSQL_USER"' not in command or 'MYSQL_PWD="$MYSQL_PASSWORD"' not in command:
            sys.exit(90)
        if 'SELECT COUNT(*) FROM patient' in command: print(0)
        else:
            query = sys.stdin.read()
            pathlib.Path(os.environ['AUDIT_TEST_SQL']).write_text(query)
            sys.stdout.write(os.environ['AUDIT_TEST_CHECKS'])
            sys.exit(int(os.environ['AUDIT_TEST_SQL_EXIT']))
    elif 'ps' in args and 'json' in args: print('[]')
elif args[0] == 'inspect' or args[:2] == ['image', 'inspect']: print('[]')
''')
                (commands / "curl").write_text("#!/bin/sh\nprintf '200'\n")
                (commands / "npm").write_text('#!/bin/sh\ntouch "$AUDIT_TEST_BROWSER"\n')
                (commands / "timeout").write_text('#!/bin/sh\nshift 2\nexec "$@"\n')
                for command in commands.iterdir(): command.chmod(0o700)
                browser = temporary / "browser-called"
                environment = {**os.environ, **fixture["environment"],
                               "PATH": str(commands) + ":" + os.environ["PATH"],
                               "GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted", "RUNNER_OS": "Linux",
                               "GITHUB_SHA": "a" * 40, "SMOKE_STATE": str(state),
                               "DOCKER_HOST": "", "DOCKER_CONTEXT": "",
                               "AUDIT_TEST_MODEL": str(temporary / "model.json"),
                               "AUDIT_TEST_SQL": str(temporary / "checks.sql"),
                               "AUDIT_TEST_CHECKS": checks, "AUDIT_TEST_SQL_EXIT": str(sql_exit),
                               "AUDIT_TEST_BROWSER": str(browser)}
                result = subprocess.run(["bash", str(runtime / "run.sh"), "local"],
                                        env=environment, capture_output=True, timeout=20)
                recorded = json.loads((repository / "runtime-smoke-results/local/result.json").read_text())
                if name == "valid":
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                    self.assertTrue(browser.exists())
                    self.assertEqual(recorded["lastStage"], "complete")
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(browser.exists())
                    self.assertEqual(recorded["lastStage"], "clinical-audit-database")
                    self.assertNotEqual(recorded["exitCode"], 0)

    def test_non_runner_cannot_reach_docker(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "docker-was-called"
            docker = root / "docker"
            docker.write_text('#!/bin/sh\ntouch "$RUNTIME_TEST_MARKER"\n')
            docker.chmod(0o700)
            environment = {**os.environ, "PATH": str(root) + ":" + os.environ["PATH"],
                           "GITHUB_ACTIONS": "false", "RUNTIME_TEST_MARKER": str(marker)}
            result = subprocess.run([sys.executable, str(ROOT / "tests/runtime/fixtures.py"),
                                     "run", str(root / "state"), "local", DIGEST], env=environment,
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(marker.exists())

    def render(self, directory, mode):
        fixture = fixtures.prepare(directory, mode, DIGEST)
        command = ["docker", "compose", "--project-name", fixture["project"], "--env-file", ".env.template",
                   "-f", "docker-compose.yml"]
        if mode == "keycloak":
            command += ["-f", "compose/keycloak.yml", "-f", "tests/runtime/compose.yml",
                        "-f", "tests/runtime/keycloak.yml", "--profile", "keycloak"]
        else:
            command += ["-f", "tests/runtime/compose.yml"]
        # Explicit files prevent a developer's .env from selecting a live stack.
        result = subprocess.run(command + ["config", "--format", "json"], cwd=ROOT,
                                env={**os.environ, **fixture["environment"]},
                                capture_output=True, text=True, timeout=30, check=True)
        subprocess.run([sys.executable, str(ROOT / "tests/runtime/fixtures.py"), "validate",
                        str(directory), str(ROOT)], input=result.stdout,
                       capture_output=True, text=True, timeout=10, check=True)
        return fixture, json.loads(result.stdout)

    def test_actual_local_and_keycloak_models_remain_isolated(self):
        for mode in ("local", "keycloak"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                fixture, model = self.render(Path(directory), mode)
                fixtures.validate_model(model, fixture, ROOT)
                backend = model["services"]["backend"]
                self.assertEqual(backend["environment"]["OMRS_EXTRA_INITIALIZER_STARTUP_LOAD"], "fail_on_error")
                self.assertEqual(backend["environment"]["OMRS_ADMIN_USER_PASSWORD"], fixture["initialPassword"])
                self.assertEqual(backend["environment"]["SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED"], "true")
                self.assertEqual(backend["environment"]["OAUTH2_ENABLED"], "true" if mode == "keycloak" else "false")
                self.assertEqual(model["services"]["frontend"]["build"]["dockerfile"], "Dockerfile")
                self.assertEqual(model["services"]["frontend"]["build"]["args"]["FRONTEND_SOURCE_IMAGE"],
                                 FRONTEND_SOURCE_IMAGE)
                if mode == "keycloak":
                    context = Path(model["services"]["keycloak"]["build"]["context"])
                    self.assertEqual(context, ROOT / "oauth")
                    self.assertTrue((context / "Dockerfile").is_file())
                    oauth_mount = next(mount for mount in backend["volumes"]
                                       if mount["target"].endswith("/oauth2login.xml"))
                    self.assertEqual(Path(oauth_mount["source"]),
                                     ROOT / "oauth/openmrs_config/globalproperties/oauth2login.xml")
                    self.assertTrue(Path(oauth_mount["source"]).is_file())

    def test_existing_external_resources_and_writable_binds_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture, model = self.render(Path(directory), "local")
            for mutation in ("volume", "container", "port", "bind", "image", "services"):
                with self.subTest(mutation=mutation):
                    bad = deepcopy(model)
                    if mutation == "volume": bad["volumes"]["db-data"]["name"] = "existing-production-data"
                    if mutation == "container": bad["services"]["backend"]["container_name"] = "sihsalus-backend"
                    if mutation == "port": bad["services"]["gateway"]["ports"][0]["host_ip"] = "0.0.0.0"
                    if mutation == "bind":
                        next(mount for mount in bad["services"]["db"]["volumes"] if mount["type"] == "bind")["read_only"] = False
                    if mutation == "image": bad["services"]["backend"]["image"] = "ghcr.io/sihsalus/sihsalus-backend:latest"
                    if mutation == "services": bad["services"]["unreviewed"] = {}
                    with self.assertRaises(ValueError): fixtures.validate_model(bad, fixture, ROOT)

    def test_logs_redact_generated_and_session_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = fixtures.prepare(Path(directory), "local", DIGEST)
            password = fixture["initialPassword"]
            text = (f"password={password}\nencoded={quote(password, safe='')}\n"
                    "Authorization: Basic YWRtaW46ZmFrZQ==\nSet-Cookie: JSESSIONID=fake-session\n"
                    "GET /callback?code=synthetic-code&state=synthetic-state&session_state=synthetic-session HTTP/1.1\n"
                    'POST /keycloak/login-actions/authenticate?session_code=private-session&execution=private-flow&tab_id=private-tab&client_data=private-context HTTP/1.1\n'
                    "token=eyJhbGciOiJub25lIn0.eyJzdWIiOiJzeW50aGV0aWMifQ.signature\n"
                    "java.lang.IllegalStateException: bootstrap failed\n")
            sanitized = fixtures.sanitize(text, fixture)
            for secret in (password, quote(password, safe=""), "YWRtaW46ZmFrZQ==", "fake-session",
                           "synthetic-code", "synthetic-state", "synthetic-session", "eyJhbGciOiJub25lIn0",
                           "private-session", "private-flow", "private-tab", "private-context"):
                self.assertNotIn(secret, sanitized)
            self.assertIn("java.lang.IllegalStateException: bootstrap failed", sanitized)

    def test_existing_fixture_is_not_overwritten_and_digest_is_required(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            with self.assertRaises(ValueError): fixtures.prepare(path, "local", "latest")
            fixtures.prepare(path, "local", DIGEST)
            with self.assertRaises(FileExistsError): fixtures.prepare(path, "keycloak", DIGEST)

    def test_generated_credentials_are_not_written_to_fixture_files(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            fixture = fixtures.prepare(path, "keycloak", DIGEST)
            self.assertEqual(sorted(p.name for p in path.iterdir()), ["fixture.json"])
            text = (path / "fixture.json").read_text()
            self.assertEqual(set(json.loads(text)), {"project", "mode", "baseURL", "backendDigest"})
            for key, value in fixture["environment"].items():
                if value and any(part in key for part in ("PASSWORD", "SECRET", "TOKEN")):
                    self.assertNotIn(value, text)


if __name__ == "__main__":
    unittest.main()
