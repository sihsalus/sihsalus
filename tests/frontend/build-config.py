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
        (root / "frontend").mkdir()
        shutil.copyfile(ROOT / "frontend/Dockerfile", root / "frontend/Dockerfile")

        def resolve(overrides=None, keycloak=False, bake_mode="explicit"):
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
            bake_files = {"explicit": [*files, "-f", "docker-bake.hcl"],
                          "implicit": [], "standalone": ["-f", "docker-bake.hcl"]}[bake_mode]
            bake = run(["docker", "buildx", "bake", *bake_files,
                        "--print", "frontend"])
            build = compose["services"]["frontend"]["build"]
            target = bake["target"]["frontend"]
            context = (root / target["context"]).resolve()
            assert context == Path(build["context"]).resolve(), f"{bake_mode}: frontend context differs"
            assert target["dockerfile"] == build["dockerfile"], f"{bake_mode}: Dockerfile differs"
            assert (context / target["dockerfile"]).is_file(), f"{bake_mode}: Dockerfile does not exist"
            args = build["args"]
            assert target["args"] == args, f"{bake_mode}: Compose/Bake frontend arguments differ"
            return args

        default = resolve()
        assert re.fullmatch(r"ghcr.io/sihsalus/sihsalus-frontend:sha-[0-9a-f]{40}@sha256:[0-9a-f]{64}",
                            default["FRONTEND_SOURCE_IMAGE"]), "Default frontend must be immutable"
        for mode in ("implicit", "standalone"):
            assert resolve(bake_mode=mode) == default
        shutil.copyfile(ROOT / ".env.template", root / ".env")
        tag = "sha-" + "1" * 40 + "@sha256:" + "2" * 64
        image = "ghcr.io/sihsalus/sihsalus-frontend@sha256:" + "3" * 64
        requested = {"FRONTEND_SOURCE_TAG": tag, "FRONTEND_SOURCE_IMAGE": image,
                     "SIHSALUS_NODE_ID": "00000000-0000-4000-8000-000000000001",
                     "STRIP_SOURCE_MAPS": "false"}
        for mode in ("explicit", "implicit", "standalone"):
            assert resolve(bake_mode=mode) == default, "Copying .env.template changed the default build"
            assert resolve({"FRONTEND_SOURCE_TAG": tag}, bake_mode=mode)["FRONTEND_SOURCE_IMAGE"].endswith(tag)
            assert resolve({key: "" for key in requested}, bake_mode=mode) == default
            args = resolve(requested, bake_mode=mode)
            for key in ("FRONTEND_SOURCE_IMAGE", "SIHSALUS_NODE_ID", "STRIP_SOURCE_MAPS"):
                assert args[key] == requested[key], f"{mode}: ignored build override: {key}"
        with (root / ".env").open("a") as env_file:
            env_file.write("\n" + "\n".join(f"{key}={value}" for key, value in requested.items()) + "\n")
        for mode in ("explicit", "implicit"):
            args = resolve(bake_mode=mode)
            for key in ("FRONTEND_SOURCE_IMAGE", "SIHSALUS_NODE_ID", "STRIP_SOURCE_MAPS"):
                assert args[key] == requested[key], f"{mode}: HCL fallback replaced .env override: {key}"
        assert "frontend-keycloak.json" in resolve(keycloak=True)["SPA_CONFIG_URLS"]
    print("[OK] Compose/Bake explicit, implicit and standalone builds, defaults, overrides and Keycloak")


if __name__ == "__main__":
    check()
