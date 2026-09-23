"""Synthetic OAuth/OIDC fixture only; never deploy or reuse as an identity provider.

Implements single-use expiring authorization codes, confidential-client auth,
PKCE S256, signed fixture JWTs and UserInfo. All users are synthetic. The fixture
selector is intentionally unauthenticated inside the owned internal CI network.
"""

import base64
import hashlib
import hmac
import json
import os
import secrets
import time
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlencode, urlsplit


PREFIX = "/realms/openmrs/protocol/openid-connect/"
CALLBACK = "http://grafana:3000/grafana/login/generic_oauth"
CLIENT = "sihsalus-grafana"
CASES = {
    "viewer": ["grafana-viewer"],
    "editor": ["grafana-editor"],
    "admin": ["grafana-admin"],
    "priority": ["grafana-viewer", "grafana-editor", "grafana-admin"],
    "empty": [],
    "unknown": ["unrelated"],
    "global_admin": ["GrafanaAdmin"],
    "scalar": "grafana-admin",
    "substring": ["not-grafana-admin"],
    "missing": None,
    "wrong_client": None,
    "realm_only": None,
    "userinfo_only": ["grafana-editor"],
    "access_only": ["grafana-admin"],
    "expired_code": ["grafana-viewer"],
    "bad_pkce": ["grafana-viewer"],
}


def b64(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode()


def claims(case, source):
    result = {
        "sub": f"synthetic-{case}",
        "preferred_username": f"synthetic-{case}",
        "email": f"{case}@example.test",
        "email_verified": True,
        "name": "Synthetic CI fixture",
        "iss": "http://keycloak:8080/realms/openmrs",
        "aud": CLIENT,
        "iat": int(time.time()),
        "exp": int(time.time()) + 300,
    }
    roles = CASES[case]
    if case == "userinfo_only" and source != "userinfo":
        roles = None
    if case == "access_only" and source != "access":
        roles = None
    if roles is not None:
        result["resource_access"] = {CLIENT: {"roles": roles}}
    if case == "wrong_client":
        result["resource_access"] = {"other-client": {"roles": ["grafana-admin"]}}
    if case == "realm_only":
        result["realm_access"] = {"roles": ["grafana-admin"]}
    return result


class Fixture:
    def __init__(self, client_secret, clock=time.monotonic):
        self.client_secret = client_secret
        self.clock = clock
        self.codes = {}
        self.tokens = {}
        self.exchanged = set()
        self.authorized = set()
        self.signing_key = secrets.token_bytes(32)

    def authorize(self, case, params):
        if case not in CASES or any(params.get(k) != v for k, v in {
            "client_id": CLIENT, "redirect_uri": CALLBACK,
            "response_type": "code", "code_challenge_method": "S256",
        }.items()) or not params.get("state") or not params.get("code_challenge"):
            raise ValueError("invalid_authorization")
        if not {"openid", "profile", "email"}.issubset(set(params.get("scope", "").split())):
            raise ValueError("invalid_scope")
        code = secrets.token_urlsafe(32)
        deadline = self.clock() - 1 if case == "expired_code" else self.clock() + 60
        challenge = "invalid-fixture-challenge" if case == "bad_pkce" else params["code_challenge"]
        self.codes[code] = (case, challenge, deadline)
        self.authorized.add(case)
        return CALLBACK + "?" + urlencode({"code": code, "state": params["state"]})

    def jwt(self, payload):
        content = b64(b'{"alg":"HS256","typ":"JWT"}') + "." + b64(json.dumps(payload).encode())
        return content + "." + b64(hmac.digest(self.signing_key, content.encode(), "sha256"))

    def exchange(self, params, client, secret):
        if client != CLIENT or not hmac.compare_digest(secret, self.client_secret):
            raise ValueError("invalid_client")
        # Refresh is deliberately rejected, not silently converted to a new login.
        if params.get("grant_type") != "authorization_code":
            raise ValueError("invalid_grant")
        item = self.codes.pop(params.get("code"), None)
        if item is None or params.get("redirect_uri") != CALLBACK:
            raise ValueError("invalid_grant")
        case, challenge, deadline = item
        if self.clock() >= deadline or b64(hashlib.sha256(params.get("code_verifier", "").encode()).digest()) != challenge:
            raise ValueError("invalid_grant")
        token = self.jwt(claims(case, "access"))
        self.tokens[token] = case
        self.exchanged.add(case)
        return {"access_token": token, "id_token": self.jwt(claims(case, "id")),
                "token_type": "Bearer", "expires_in": 300}


class Handler(BaseHTTPRequestHandler):
    fixture = None

    def log_message(self, *_args):
        pass  # No URLs, authorization codes, cookies, tokens or bodies in logs.

    def respond(self, status, body=None, headers=None):
        data = json.dumps(body or {}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urlsplit(self.path)
        if parsed.path == "/health":
            return self.respond(200, {"ready": True})
        if parsed.path.startswith("/evidence/"):
            case = parsed.path.removeprefix("/evidence/")
            if case not in CASES:
                return self.respond(400)
            return self.respond(200, {"authorized": case in self.fixture.authorized,
                                      "exchanged": case in self.fixture.exchanged})
        if parsed.path.startswith("/fixture/"):
            case = parsed.path.removeprefix("/fixture/")
            if case not in CASES:
                return self.respond(400)
            return self.respond(200, headers={"Set-Cookie": f"fixture={case}; Path=/; HttpOnly; SameSite=Lax"})
        if parsed.path == PREFIX + "auth":
            cookie = SimpleCookie(self.headers.get("Cookie", ""))
            case = cookie["fixture"].value if "fixture" in cookie else ""
            params = {key: values[0] for key, values in parse_qs(parsed.query).items()}
            try:
                redirect = self.fixture.authorize(case, params)
            except ValueError:
                return self.respond(400, {"error": "invalid_request"})
            return self.respond(302, headers={"Location": redirect})
        if parsed.path == PREFIX + "userinfo":
            token = self.headers.get("Authorization", "").removeprefix("Bearer ")
            case = self.fixture.tokens.get(token)
            if case is None:
                return self.respond(401)
            return self.respond(200, claims(case, "userinfo"))
        self.respond(404)

    def do_POST(self):
        if self.path != PREFIX + "token":
            return self.respond(404)
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 < length <= 8192:
            return self.respond(400)
        params = {key: values[0] for key, values in parse_qs(self.rfile.read(length).decode()).items()}
        client, secret = params.get("client_id", ""), params.get("client_secret", "")
        if self.headers.get("Authorization", "").startswith("Basic "):
            try:
                client, secret = base64.b64decode(self.headers["Authorization"][6:], validate=True).decode().split(":", 1)
            except (ValueError, UnicodeError):
                return self.respond(401, {"error": "invalid_client"})
        try:
            token = self.fixture.exchange(params, client, secret)
        except ValueError as error:
            return self.respond(400, {"error": str(error)})
        self.respond(200, token)


if __name__ == "__main__":
    Handler.fixture = Fixture(os.environ["SYNTHETIC_OIDC_SECRET"])
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
