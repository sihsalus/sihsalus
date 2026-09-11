"""Validate the rendered opt-in contract; no connection to any service."""

import json
import sys


ROLE_PATH = (
    'contains(resource_access."sihsalus-grafana".roles[*], \'grafana-admin\') && \'Admin\' '
    '|| contains(resource_access."sihsalus-grafana".roles[*], \'grafana-editor\') && \'Editor\' '
    '|| contains(resource_access."sihsalus-grafana".roles[*], \'grafana-viewer\') && \'Viewer\''
)


def validate(model, baseline):
    services = model["services"]
    assert set(services) == set(baseline["services"]), "service_set_changed"
    # The override must not change any clinical/identity service or provision data.
    for name, service in baseline["services"].items():
        if name != "grafana":
            assert services[name] == service, "non_grafana_service_changed"
    grafana = services["grafana"]
    env = grafana["environment"]
    required = {
        "GF_AUTH_GENERIC_OAUTH_ENABLED": "true",
        "GF_AUTH_GENERIC_OAUTH_CLIENT_ID": "sihsalus-grafana",
        "GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_STRICT": "true",
        "GF_AUTH_GENERIC_OAUTH_ALLOW_ASSIGN_GRAFANA_ADMIN": "false",
        "GF_AUTH_GENERIC_OAUTH_SKIP_ORG_ROLE_SYNC": "false",
        "GF_AUTH_GENERIC_OAUTH_USE_PKCE": "true",
        "GF_AUTH_GENERIC_OAUTH_USE_REFRESH_TOKEN": "true",
        "GF_AUTH_GENERIC_OAUTH_ALLOW_SIGN_UP": "true",
        "GF_AUTH_GENERIC_OAUTH_AUTO_LOGIN": "false",
        "GF_AUTH_GENERIC_OAUTH_SIGNOUT_REDIRECT_URL": "",
        "GF_AUTH_SIGNOUT_REDIRECT_URL": "",
        "GF_AUTH_DISABLE_LOGIN_FORM": "false",
        "GF_AUTH_OAUTH_ALLOW_INSECURE_EMAIL_LOOKUP": "false",
        "GF_AUTH_ANONYMOUS_ENABLED": "false",
        "GF_USERS_ALLOW_SIGN_UP": "false",
        "GF_SECURITY_COOKIE_SECURE": "true",
        "GF_SECURITY_COOKIE_SAMESITE": "lax",
        "GF_SERVER_SERVE_FROM_SUB_PATH": "true",
    }
    for key, value in required.items():
        assert env.get(key) == value, f"invalid_{key}"
    assert " ".join(env["GF_AUTH_GENERIC_OAUTH_ROLE_ATTRIBUTE_PATH"].split()) == ROLE_PATH, "role_mapping_changed"
    assert env["GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET"], "missing_client_secret"
    assert env["GF_SERVER_ROOT_URL"].startswith("https://") and env["GF_SERVER_ROOT_URL"].endswith("/grafana/"), "invalid_root_url"
    assert env["GF_AUTH_GENERIC_OAUTH_AUTH_URL"].startswith("https://"), "invalid_authorization_url"
    for key, suffix in (("TOKEN_URL", "token"), ("API_URL", "userinfo")):
        assert env[f"GF_AUTH_GENERIC_OAUTH_{key}"] == f"http://keycloak:8080/realms/openmrs/protocol/openid-connect/{suffix}", "invalid_internal_endpoint"
    assert "auth-network" in grafana["networks"], "missing_auth_network"
    assert "monitoring-network" in grafana["networks"], "missing_monitoring_network"
    assert grafana["depends_on"]["keycloak"]["condition"] == "service_healthy", "missing_keycloak_readiness"
    assert all(port.get("host_ip") == "127.0.0.1" for port in grafana["ports"]), "non_loopback_port"
    assert grafana["image"] == "grafana/grafana:12.3", "unreviewed_grafana_image"


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as handle:
        candidate = json.load(handle)
    with open(sys.argv[2], encoding="utf-8") as handle:
        original = json.load(handle)
    validate(candidate, original)
    print("[OK] Grafana opt-in OIDC Compose contract")
