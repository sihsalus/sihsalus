#!/usr/bin/env python3
"""Exercise real Compose merging with synthetic configuration; no Docker daemon."""

import argparse
import json
from pathlib import Path
import tempfile
from unittest.mock import patch

from test_release_manifest import ROOT, digest, fixture, release


SYNTHETIC_ENV = """DEPLOYMENT_ENV=production
OAUTH2_CLIENT_SECRET=synthetic-compose-validation
KEYCLOAK_ADMIN_PASSWORD=synthetic-compose-validation
KC_DB_PASSWORD=synthetic-compose-validation
IMAGING_OIDC_CLIENT_SECRET=synthetic-compose-validation
IMAGING_OAUTH_COOKIE_SECRET=c3ludGhldGljLWNvb2tpZS0zMmJ5dGVzLWtleS0xMjM=
IMAGING_REDIS_PASSWORD=synthetic-compose-validation
GRAFANA_ROOT_URL=https://test.invalid/grafana/
GRAFANA_OIDC_CLIENT_SECRET=synthetic-compose-validation
KEYCLOAK_PUBLIC_URL=https://test.invalid/keycloak
"""


def exercise_profiles(env_file):
    selections = [
        ([], []),
        (["fua"], []),
        (["hapi", "indicadores", "replica"], []),
        (["monitoring", "logs"], []),
        (["keycloak", "ssl", "imaging"], ["compose/keycloak.yml", "compose/ssl.yml", "compose/imaging-auth.yml"]),
        (["keycloak", "monitoring"], ["compose/keycloak.yml", "compose/monitoring-oidc.yml"]),
    ]
    for profiles, files in selections:
        manifest = fixture()
        manifest["target"]["environment"] = "production"
        manifest["compose"]["profiles"] = profiles
        manifest["compose"]["files"].extend(files)
        active = release.run(release.compose_command(manifest, env_file) + ["config", "--services"],
                             root=ROOT, environment=release.compose_environment(manifest)).splitlines()
        for service in active:
            if service not in manifest["services"]:
                manifest["services"][service] = {"image": digest(service), "imageId": digest(service)}
        release.verify_compose(manifest, ROOT, env_file)
        print(f"PASS: production Compose selection {','.join(profiles) or 'core'} pins {len(active)} services")

    # Explicit validation ignores inherited profiles, but the persistent audit
    # must reject an ordinary Compose invocation that selects another profile.
    import os
    with patch.dict(os.environ, {"COMPOSE_PROFILES": "fua"}):
        release.verify_compose(fixture(), ROOT, env_file)


def exercise_persistent_selection(directory, audit=False):
    # Match the CLI's canonical paths (macOS /var aliases /private/var).
    directory = directory.resolve()
    manifest = fixture()
    if audit:
        manifest["target"]["environment"] = "production"
        manifest["sources"]["distroCommit"] = release.run(["git", "rev-parse", "HEAD"], root=ROOT).strip()
    digest_value = release.manifest_digest(manifest)
    path = directory / f"{digest_value}.json"
    override = directory / f"{digest_value}.compose.json"
    release.write_new(path, manifest)
    release.write_new(override, release.compose_override(manifest))
    selection = {
        "DEPLOYMENT_ENV": manifest["target"]["environment"], "COMPOSE_FILE": f"{ROOT / 'docker-compose.yml'}:{override}",
        "COMPOSE_PROFILES": "", "COMPOSE_PROJECT_NAME": manifest["compose"]["project"],
        "DOCKER_DEFAULT_PLATFORM": manifest["compose"]["platform"],
        "SIHSALUS_NODE_ID": manifest["target"]["nodeId"], "SIHSALUS_RELEASE_MANIFEST": str(path),
        "MYSQL_OPENMRS_PASSWORD": "synthetic-validation-password-1", "MYSQL_ROOT_PASSWORD": "synthetic-validation-password-2",
    }
    env_file = directory / "selected.env"
    env_file.write_text(release.select_manifest("", selection))
    env_file.chmod(0o600)
    # Checkout guards use real Git in the unit suite. This case isolates the
    # actual daemonless Compose selection and can run before a local commit.
    with patch.object(release, "verify_checkout"):
        release.verify_selected_compose(manifest, ROOT, env_file, path)
        import os
        with patch.dict(os.environ, {"COMPOSE_PROFILES": "fua"}):
            try:
                release.verify_selected_compose(manifest, ROOT, env_file, path)
            except release.ManifestError:
                pass
            else:
                raise AssertionError("Inherited unreviewed profile was accepted")
    print("PASS: actual persistent Compose selection; inherited profile drift rejected")
    if audit:
        output = release.run(["bash", "scripts/security-audit.sh", str(env_file)], root=ROOT)
        assert "Every enabled service uses its reviewed immutable release image" in output
        assert "Audit complete: 0 issue(s)" in output
        print("PASS: production security audit consumes effective manifest pins with the existing secret/configuration checks")


def exercise_catalog(env_file):
    for path in sorted((ROOT / "releases").rglob("*.json")):
        manifest = release.validate_manifest(release.read_json(path))
        commit = manifest["sources"]["distroCommit"]
        # Publication can only reference a distro commit present in this history.
        release.run(["git", "merge-base", "--is-ancestor", commit, "HEAD"], root=ROOT)
        with tempfile.TemporaryDirectory(prefix="release-source-") as directory:
            checkout = Path(directory) / "checkout"
            release.run(["git", "worktree", "add", "--detach", str(checkout), commit], root=ROOT)
            try:
                release.verify_checkout(manifest, checkout)
                release.verify_compose(manifest, checkout, env_file)
            finally:
                release.run(["git", "worktree", "remove", str(checkout)], root=ROOT)
        print(f"PASS: reviewed catalog release {manifest['releaseId']} covers its source Compose services")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", action="store_true")
    parser.add_argument("--audit", action="store_true", help="Also exercise security-audit.sh; requires a clean committed checkout")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="release-compose-") as directory:
        env_file = Path(directory) / "synthetic.env"
        env_file.write_text(SYNTHETIC_ENV)
        exercise_profiles(env_file)
        exercise_persistent_selection(Path(directory), audit=args.audit)
        if args.catalog:
            exercise_catalog(env_file)
