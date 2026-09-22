#!/usr/bin/env python3
"""CI-only SPDX, scan and promotion proof using a loopback registry and fake packages."""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from uuid import uuid4


ROOT = Path(__file__).resolve().parents[2]
SENTINEL = "SYNTHETIC_CREDENTIAL_MUST_NOT_APPEAR_IN_EVIDENCE"


def run(command, root, timeout=180, allow_failure=False):
    result = subprocess.run(command, cwd=root, text=True, capture_output=True, timeout=timeout)
    if result.returncode and not allow_failure:
        # All inputs are synthetic; still exercise the same bounded logging rule.
        diagnostic = "\n".join((result.stdout + result.stderr).splitlines()[-20:]).replace(SENTINEL, "[synthetic value redacted]")
        raise RuntimeError("Isolated image-security command failed: " + " ".join(command[:2]) + "\n" + diagnostic)
    return result


def main():
    run(["docker", "context", "show"], ROOT)
    run(["docker", "info", "--format", "{{.ServerVersion}}"], ROOT)
    identifier = "image-security-" + uuid4().hex[:12]
    builder = identifier + "-builder"
    source = run(["git", "rev-parse", "HEAD"], ROOT).stdout.strip()
    with tempfile.TemporaryDirectory(prefix=identifier) as directory:
        root = Path(directory)
        (root / "scripts/security").mkdir(parents=True)
        (root / "security").mkdir()
        shutil.copy2(ROOT / "scripts/security/image-policy.py", root / "scripts/security/image-policy.py")
        shutil.copy2(ROOT / "security/image-exceptions.json", root / "security/image-exceptions.json")
        (root / "os-release").write_text('NAME="Alpine Linux"\nID=alpine\nVERSION_ID=3.23.0\nPRETTY_NAME="Alpine Linux v3.23"\n')
        (root / "alpine-release").write_text("3.23.0\n")
        for target, architecture in (("amd64", "x86_64"), ("arm64", "aarch64")):
            (root / ("installed-" + target)).write_text(
                "C:Q1AAAAAAAAAAAAAAAAAAAAAAAAAAA=\nP:sihsalus-security-proof\nV:1.0.0-r0\n"
                f"A:{architecture}\nS:1\nI:1\nT:Synthetic security test package\n"
                "U:https://example.invalid/\nL:MIT\no:sihsalus-security-proof\nm:Synthetic fixture\nt:1700000000\n\n"
            )
        (root / "Dockerfile").write_text(
            "FROM scratch\nARG TARGETARCH\nARG SOURCE_SHA\nLABEL org.opencontainers.image.revision=${SOURCE_SHA}\n"
            "COPY os-release /etc/os-release\nCOPY alpine-release /etc/alpine-release\n"
            "COPY installed-${TARGETARCH} /lib/apk/db/installed\n"
            f"ENV SYNTHETIC_TEST_TOKEN={SENTINEL}\n"
        )
        registry_created = False
        builder_created = False
        try:
            run(["docker", "run", "--detach", "--name", identifier, "--publish", "127.0.0.1::5000",
                 "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                 "registry:3@sha256:325b4b29b041e82803abeb703e201655e4e23ab83264ec1a7c9ddb0a5b14a6e0"], root)
            registry_created = True
            port = run(["docker", "inspect", identifier, "--format",
                        '{{(index (index .NetworkSettings.Ports "5000/tcp") 0).HostPort}}'], root).stdout.strip()
            assert port.isdigit()
            repository = f"127.0.0.1:{port}/sihsalus-security-proof"
            run(["docker", "buildx", "create", "--name", builder, "--driver", "docker-container",
                 "--driver-opt", "network=host"], root)
            builder_created = True
            # No RUN, emulation or product startup: only metadata and a fake APK
            # database. BuildKit's real SBOM generator inventories both images.
            run(["docker", "buildx", "build", "--builder", builder, "--platform", "linux/amd64,linux/arm64",
                 "--build-arg", "SOURCE_SHA=" + source,
                 "--sbom=true", "--provenance=mode=max", "--metadata-file", "build.json",
                 "--output", "type=image,push=true,registry.insecure=true", "--tag", repository + ":candidate", "."], root, timeout=600)
            digest = json.loads((root / "build.json").read_text())["containerimage.digest"]
            image = repository + "@" + digest
            result = run(["bash", str(ROOT / "scripts/security/scan-image.sh"), image, source, "security-evidence"], root, timeout=1200)
            evidence = json.loads((root / "security-evidence/evidence.json").read_text())
            assert evidence["decision"] == "pass" and evidence["blockedFindings"] == 0
            assert {item["platform"] for item in evidence["platforms"]} == {"linux/amd64", "linux/arm64"}
            assert all(item["sbom"]["packageCount"] >= 1 for item in evidence["platforms"])
            assert SENTINEL not in json.dumps(evidence) + result.stdout + result.stderr
            run(["bash", str(ROOT / "scripts/security/promote-image.sh"), image, source, "true"], root)
            for tag in ("sha-" + source, "latest"):
                actual = run(["docker", "buildx", "imagetools", "inspect", repository + ":" + tag,
                              "--format", "{{.Manifest.Digest}}"], root).stdout.strip()
                assert actual == digest
            print("PASS: real multi-platform SPDX, exact-child Trivy scans, credential-free evidence and digest-preserving aliases")
        finally:
            if builder_created:
                run(["docker", "buildx", "rm", "--force", builder], root, allow_failure=True)
            if registry_created:
                # Removes only this run's registry and its anonymous test volume.
                run(["docker", "rm", "--force", "--volumes", identifier], root, allow_failure=True)


if __name__ == "__main__":
    main()
