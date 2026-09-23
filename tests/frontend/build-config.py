#!/usr/bin/env python3
"""Compare resolved Compose/Bake arguments without a daemon or local secrets."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def check():
    environment = {key: os.environ[key] for key in
                   ("PATH", "HOME", "DOCKER_CONFIG", "DOCKER_HOST", "DOCKER_CONTEXT", "TMPDIR")
                   if key in os.environ}
    with tempfile.TemporaryDirectory(prefix="sihsalus-build-config-") as directory:
        root = Path(directory)
        for name in ("docker-compose.yml", "docker-bake.hcl"):
            shutil.copyfile(ROOT / name, root / name)
        shutil.copytree(ROOT / "compose", root / "compose")

        def resolve(overrides=None, keycloak=False):
            env = dict(environment, **(overrides or {}))
            if keycloak:
                for key in ("OAUTH2_CLIENT_SECRET", "KEYCLOAK_ADMIN_PASSWORD",
                            "IMAGING_OIDC_CLIENT_SECRET", "KC_DB_PASSWORD"):
                    env[key] = "synthetic-build-config-only"
            files = ["-f", "docker-compose.yml"]
            if keycloak:
                files += ["-f", "compose/keycloak.yml"]

            def run(command):
                result = subprocess.run(command, cwd=root, env=env, check=True,
                                        capture_output=True, text=True, timeout=30)
                return json.loads(result.stdout)

            profiles = ["--profile", "keycloak"] if keycloak else []
            compose = run(["docker", "compose", *files, *profiles, "config", "--format", "json"])
            bake = run(["docker", "buildx", "bake", *files, "-f", "docker-bake.hcl",
                        "--print", "frontend"])
            args = compose["services"]["frontend"]["build"]["args"]
            assert bake["target"]["frontend"]["args"] == args, "Compose/Bake frontend arguments differ"
            return args

        default = resolve()
        assert re.fullmatch(r"ghcr.io/sihsalus/sihsalus-frontend:sha-[0-9a-f]{40}@sha256:[0-9a-f]{64}",
                            default["FRONTEND_SOURCE_IMAGE"]), "Default frontend must be immutable"
        shutil.copyfile(ROOT / ".env.template", root / ".env")
        assert resolve() == default, "Copying .env.template must preserve the default build"
        tag = "sha-" + "1" * 40 + "@sha256:" + "2" * 64
        assert resolve({"FRONTEND_SOURCE_TAG": tag})["FRONTEND_SOURCE_IMAGE"].endswith(tag)
        image = "ghcr.io/sihsalus/sihsalus-frontend@sha256:" + "3" * 64
        requested = {"FRONTEND_SOURCE_TAG": tag, "FRONTEND_SOURCE_IMAGE": image,
                     "SIHSALUS_NODE_ID": "00000000-0000-4000-8000-000000000001",
                     "STRIP_SOURCE_MAPS": "false"}
        args = resolve(requested)
        for key in ("FRONTEND_SOURCE_IMAGE", "SIHSALUS_NODE_ID", "STRIP_SOURCE_MAPS"):
            assert args[key] == requested[key], f"Ignored build override: {key}"
        assert "frontend-keycloak.json" in resolve(keycloak=True)["SPA_CONFIG_URLS"]
    print("[OK] Compose/Bake defaults, template, source precedence, node and Keycloak arguments")


if __name__ == "__main__":
    check()
