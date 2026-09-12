#!/usr/bin/env python3
"""Check rendered local OpenMRS auth without changing the Imaging OIDC stack."""
from copy import deepcopy
import json
from pathlib import Path
import sys


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def validate_models(evidence):
    def load(name):
        return json.loads((evidence / f"{name}.json").read_text(encoding="utf-8"))

    core = load("core")
    pairs = (
        ("keycloak", "keycloak-local-auth"),
        ("imaging-auth", "imaging-local-auth"),
        ("imaging-auth-ssl", "imaging-local-auth-ssl"),
        ("imaging-auth-fua", "imaging-local-auth-fua"),
    )
    for standard_name, local_name in pairs:
        standard = load(standard_name)
        local = load(local_name)
        services = local["services"]
        backend = services["backend"]
        generator = services["backend-oauth2-config"]
        frontend_args = services["frontend"]["build"]["args"]

        require(backend["environment"]["OAUTH2_ENABLED"] == "false", local_name)
        require(generator["environment"]["OAUTH2_ENABLED"] == "false", local_name)
        require(frontend_args["SPA_CONFIG_URLS"] == "/openmrs/spa/frontend.json", local_name)
        require("keycloak" not in backend["depends_on"], local_name)
        require(backend["depends_on"] == core["services"]["backend"]["depends_on"], local_name)
        require(backend["volumes"] == core["services"]["backend"]["volumes"], local_name)
        require(not any("oauth2login.xml" in volume["target"] for volume in backend["volumes"]), local_name)
        require(generator["volumes"] == core["services"]["backend-oauth2-config"]["volumes"], local_name)

        # Only the explicit OpenMRS auth settings may differ. This also guards
        # every Imaging service, ACL, role, network, database and volume against
        # accidental changes in HTTP, HTTPS and the FUA combination.
        expected = deepcopy(standard)
        for name in ("backend", "backend-oauth2-config"):
            expected["services"][name]["environment"]["OAUTH2_ENABLED"] = "false"
        expected["services"]["frontend"]["build"]["args"]["SPA_CONFIG_URLS"] = frontend_args["SPA_CONFIG_URLS"]
        expected["services"]["backend"]["depends_on"].pop("keycloak")
        expected["services"]["backend"]["volumes"] = core["services"]["backend"]["volumes"]
        require(local == expected, f"{local_name}: unrelated service or resource changed")

    rollback = load("imaging-local-auth-rollback")
    expected = deepcopy(load("imaging-local-auth"))
    expected["services"]["backend"]["environment"]["SIHSALUS_FORCED_PASSWORD_CHANGE_ENABLED"] = "false"
    require(rollback == expected, "local auth must preserve the forced-password feature opt-out")

    print("[OK] local OpenMRS auth: Keycloak, Imaging HTTP/HTTPS, FUA, password feature opt-out and unchanged protections")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: local-auth-config.py EVIDENCE_DIRECTORY")
    validate_models(Path(sys.argv[1]))
