"""Real Grafana login regression, restricted to ephemeral GitHub-hosted CI.

Only the owned internal network is reachable by the test containers. No host
ports, Docker socket mounts, existing config/data or external identity provider.
"""

import copy
import http.cookiejar
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

from config import validate
from provider import CASES


HERE = Path(__file__).resolve().parent
PYTHON_IMAGE = "python:3.13-alpine@sha256:7415fbc3c9e4979cc717d92377ab2bc7b2b4a2af1ac03cc52b5f3f88efedaf3a"
ORIGINS = {"http://grafana:3000", "http://keycloak:8080"}
GRAFANA = "http://grafana:3000/grafana"
PROVIDER = "http://keycloak:8080"
CLIENT_FAILURE_CODES = frozenset({
    "redirect_outside_fixture", "fixture_http_unavailable", "redirect_without_location",
    "redirect_limit", "fixture_invalid_json", "fixture_startup_timeout", "anonymous_not_denied",
    "fixture_selection_failed", "authorization_not_exercised", "unexpected_token_exchange",
    "unmapped_login_not_denied", "mapped_login_failed", "unexpected_identity", "global_admin_assigned",
    "unexpected_organization_role", "logout_cookie_not_cleared", "logout_session_not_revoked",
    "unexpected_fixture_error",
})


class Failure(Exception):
    """Only static, public-safe diagnostic codes may be emitted."""


def repository_root():
    # The container client is mounted at /test; it never needs a repository root.
    parents = Path(__file__).resolve().parents
    require(len(parents) > 3, "host_repository_required")
    return parents[3]


def require(condition, code):
    if not condition:
        raise Failure(code)


def allowed_url(url):
    parsed = urllib.parse.urlsplit(url)
    return (f"{parsed.scheme}://{parsed.netloc}" in ORIGINS
            and parsed.username is None and parsed.password is None)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


class Browser:
    """HTTP cookie-jar client, not a browser UI/SameSite/TLS acceptance test."""

    def __init__(self, cookies=None):
        self.cookies = cookies if cookies is not None else http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(self.cookies), NoRedirect())

    def get(self, url, follow=False):
        for _ in range(12):
            require(allowed_url(url), "redirect_outside_fixture")
            try:
                response = self.opener.open(url, timeout=5)
            except urllib.error.HTTPError as error:
                response = error
            except (urllib.error.URLError, TimeoutError, OSError):
                raise Failure("fixture_http_unavailable") from None
            with response:
                status = response.code
                location = response.headers.get("Location")
                body = response.read(1024 * 1024)
            if follow and status in (301, 302, 303, 307, 308):
                require(location is not None, "redirect_without_location")
                url = urllib.parse.urljoin(url, location)
                continue
            return status, body
        raise Failure("redirect_limit")

    def api(self, url):
        status, body = self.get(url)
        try:
            return status, json.loads(body)
        except (ValueError, UnicodeError):
            raise Failure("fixture_invalid_json") from None

    def snapshot_session(self):
        # CookieJar owns an RLock and cannot be deep-copied.
        jar = http.cookiejar.CookieJar()
        for cookie in self.cookies:
            jar.set_cookie(copy.copy(cookie))
        return Browser(jar)


def exercise():
    deadline = time.monotonic() + 120
    while True:
        try:
            require(Browser().api(GRAFANA + "/api/health")[0] == 200, "grafana_not_ready")
            require(Browser().api(PROVIDER + "/health") == (200, {"ready": True}), "provider_not_ready")
            break
        except Failure:
            if time.monotonic() >= deadline:
                raise Failure("fixture_startup_timeout") from None
            time.sleep(2)

    require(Browser().get(GRAFANA + "/api/user")[0] == 401, "anonymous_not_denied")
    permitted = {"viewer": "Viewer", "editor": "Editor", "admin": "Admin", "priority": "Admin",
                 "userinfo_only": "Editor", "access_only": "Admin"}
    for case in CASES:
        browser = Browser()
        require(browser.get(PROVIDER + "/fixture/" + case)[0] == 200, "fixture_selection_failed")
        browser.get(GRAFANA + "/login/generic_oauth", follow=True)
        status, evidence = browser.api(PROVIDER + "/evidence/" + case)
        require(status == 200 and evidence.get("authorized") is True, "authorization_not_exercised")
        require(evidence.get("exchanged") is (case not in ("expired_code", "bad_pkce")), "unexpected_token_exchange")
        status, user = browser.api(GRAFANA + "/api/user")
        if case not in permitted:
            require(status == 401, "unmapped_login_not_denied")
        else:
            require(status == 200 and isinstance(user, dict), "mapped_login_failed")
            require(user.get("login") == "synthetic-" + case, "unexpected_identity")
            require(user.get("isGrafanaAdmin") is False, "global_admin_assigned")
            status, orgs = browser.api(GRAFANA + "/api/user/orgs")
            require(status == 200 and isinstance(orgs, list) and len(orgs) == 1
                    and orgs[0].get("role") == permitted[case], "unexpected_organization_role")
            # Reuse the pre-logout cookie to prove server-side invalidation too.
            old_session = browser.snapshot_session()
            browser.get(GRAFANA + "/logout", follow=True)
            require(browser.get(GRAFANA + "/api/user")[0] == 401, "logout_cookie_not_cleared")
            require(old_session.get(GRAFANA + "/api/user")[0] == 401, "logout_session_not_revoked")
        print(json.dumps({"case": case, "result": "PASSED"}), flush=True)
    print(json.dumps({"scope": "real_grafana_synthetic_oidc", "cases": len(CASES), "result": "PASSED"}), flush=True)


def checked(args, operation, *, env=None, timeout=60, accepted_codes=(0,)):
    if args and args[0] == "docker" and env is None:
        # Runtime never inherits a remote Docker host/context from the runner.
        args = ["docker", "--host", "unix:///var/run/docker.sock", *args[1:]]
        env = {"PATH": os.environ["PATH"], "HOME": os.environ.get("HOME", "/tmp")}
    try:
        result = subprocess.run(args, cwd=repository_root(), env=env, text=True,
                                capture_output=True, timeout=timeout, check=False)
    except (subprocess.TimeoutExpired, OSError):
        raise Failure(operation + "_unavailable") from None
    require(result.returncode in accepted_codes, operation + "_failed")
    return result.stdout


def publish_evidence(output):
    seen = set()
    complete = False
    for line in output.splitlines():
        item = json.loads(line)
        require(isinstance(item, dict), "invalid_test_evidence")
        if item.get("result") == "FAILED":
            code = item.get("code")
            require(code in CLIENT_FAILURE_CODES, "invalid_test_evidence")
            raise Failure(code)
        require(item.get("result") == "PASSED", "invalid_test_evidence")
        if set(item) == {"case", "result"}:
            require(item["case"] in CASES and item["case"] not in seen, "invalid_test_evidence")
            seen.add(item["case"])
        else:
            require(item == {"scope": "real_grafana_synthetic_oidc", "cases": len(CASES), "result": "PASSED"}, "invalid_test_evidence")
            complete = True
        print(json.dumps(item), flush=True)
    require(complete and seen == set(CASES), "incomplete_test_evidence")


def render():
    # No .env or inherited operational secrets can influence the rendered model.
    env = {"PATH": os.environ["PATH"], "HOME": os.environ.get("HOME", "/tmp")}
    for name in ("KEYCLOAK_ADMIN_PASSWORD", "KC_DB_PASSWORD", "OAUTH2_CLIENT_SECRET",
                 "IMAGING_OIDC_CLIENT_SECRET", "GRAFANA_ADMIN_PASSWORD", "GRAFANA_OIDC_CLIENT_SECRET"):
        env[name] = "synthetic-fixture-only-" + name.lower()
    env.update(GRAFANA_ROOT_URL="https://sihsalus.example.test/grafana/",
               KEYCLOAK_PUBLIC_URL="https://sihsalus.example.test/keycloak")
    command = ["docker", "compose", "--env-file", "/dev/null", "-f", "docker-compose.yml", "-f", "compose/keycloak.yml"]
    profiles = ["--profile", "keycloak", "--profile", "monitoring", "config", "--format", "json"]
    base = json.loads(checked(command + profiles, "compose_baseline", env=env))
    model = json.loads(checked(command + ["-f", "compose/monitoring-oidc.yml"] + profiles, "compose_oidc", env=env))
    validate(model, base)
    return model["services"]["grafana"]


class OwnedDocker:
    def __init__(self):
        self.owner = "sihsalus-grafana-oidc-" + secrets.token_hex(8)
        self.resources = []

    def create(self, kind, suffix, args):
        name = self.owner + "-" + suffix
        # Journal BEFORE create: a timeout can still create a Docker resource.
        self.resources.append((kind, name))
        if kind == "network":
            command = ["docker", "network", "create", "--label", "sihsalus.oidc-test=" + self.owner, *args, name]
        else:
            command = ["docker", "create", "--name", name, "--label", "sihsalus.oidc-test=" + self.owner, *args]
        checked(command, "create_" + kind)
        return name

    def cleanup(self):
        deadline = time.monotonic() + 150
        failed = False
        for kind, name in reversed(self.resources):
            try:
                timeout = max(1, min(30, int(deadline - time.monotonic())))
                # Listing finds absence without conflating an inspect/daemon failure.
                ids = checked(["docker", kind, "ls", *( ["-a"] if kind == "container" else []),
                               "--filter", "name=" + name, "--format", "{{.Name}}" if kind == "network" else "{{.Names}}"],
                              "cleanup_list", timeout=timeout).splitlines()
                if name not in ids:
                    continue
                info = json.loads(checked(["docker", kind, "inspect", name], "cleanup_inspect", timeout=timeout))[0]
                labels = info.get("Labels", {}) if kind == "network" else info.get("Config", {}).get("Labels", {})
                require(labels.get("sihsalus.oidc-test") == self.owner, "cleanup_owner_mismatch")
                checked(["docker", kind, "rm", *( ["-f", "-v"] if kind == "container" else []), name], "cleanup_remove", timeout=timeout)
            except (Failure, ValueError, KeyError, IndexError):
                failed = True
        require(not failed, "owned_cleanup_failed")


def runtime():
    require(os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted", "ephemeral_ci_required")
    grafana = render()
    for image in (grafana["image"], PYTHON_IMAGE):
        checked(["docker", "pull", image], "image_pull", timeout=180)
    owned = OwnedDocker()
    try:
        with tempfile.TemporaryDirectory(prefix="sihsalus-grafana-oidc-") as directory:
            secret = secrets.token_hex(32)
            env = dict(grafana["environment"])
            env.update(GF_SERVER_ROOT_URL=GRAFANA + "/", GF_SECURITY_COOKIE_SECURE="false",
                       GF_AUTH_GENERIC_OAUTH_AUTH_URL=PROVIDER + "/realms/openmrs/protocol/openid-connect/auth",
                       GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=secret, GF_SECURITY_ADMIN_PASSWORD=secrets.token_hex(32),
                       GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH="", GF_PLUGINS_PREINSTALL_DISABLED="true")
            # The only transport differences are isolated HTTP endpoints/cookie; the
            # auth policy and Grafana image come from the actual rendered override.
            grafana_env = Path(directory) / "grafana.env"
            provider_env = Path(directory) / "provider.env"
            for path, values in ((grafana_env, env), (provider_env, {"SYNTHETIC_OIDC_SECRET": secret})):
                path.touch(mode=0o600)
                path.write_text("".join(f"{key}={value}\n" for key, value in values.items()), encoding="utf-8")
            network = owned.create("network", "network", ["--internal"])
            safe = ["--network", network, "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--read-only"]
            provider = owned.create("container", "provider", [*safe, "--network-alias", "keycloak", "--user", "65534:65534",
                "--env-file", str(provider_env), "--mount", f"type=bind,src={HERE},dst=/test,readonly",
                "--entrypoint", "python", PYTHON_IMAGE, "-B", "/test/provider.py"])
            server = owned.create("container", "grafana", [*safe, "--network-alias", "grafana", "--env-file", str(grafana_env),
                "--tmpfs", "/var/lib/grafana:uid=472,gid=0,mode=0700", "--tmpfs", "/tmp", grafana["image"]])
            client = owned.create("container", "client", [*safe, "--user", "65534:65534",
                "--mount", f"type=bind,src={HERE},dst=/test,readonly", "--entrypoint", "python", PYTHON_IMAGE,
                "-B", "/test/runtime.py", "client"])
            for name in (provider, server):
                checked(["docker", "start", name], "fixture_start")
            # stdout is our fixed JSON evidence only; do not print container logs.
            result = checked(["docker", "start", "-a", client], "login_regressions", timeout=300, accepted_codes=(0, 1))
            publish_evidence(result)
            info = json.loads(checked(["docker", "container", "inspect", client], "client_exit"))[0]
            require(info["State"]["ExitCode"] == 0, "client_failed")
    finally:
        owned.cleanup()
    print('{"scope":"owned_cleanup","result":"PASSED"}')


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["client"]:
            exercise()
        elif sys.argv[1:] == ["runtime"]:
            runtime()
        else:
            raise Failure("invalid_command")
    except Failure as error:
        print(json.dumps({"result": "FAILED", "code": str(error)}), flush=True)
        sys.exit(1)
    except Exception:
        print('{"result":"FAILED","code":"unexpected_fixture_error"}', flush=True)
        sys.exit(1)
