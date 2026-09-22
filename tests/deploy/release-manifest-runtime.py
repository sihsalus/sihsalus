#!/usr/bin/env python3
"""CI-only Docker boundary proof with scratch images, no network or clinical data."""

import json
from pathlib import Path
import subprocess
import tempfile
from uuid import uuid4

from test_release_manifest import fixture, release


def execute(command, root):
    return release.run(command, root=root)


def main():
    project = "manifest-proof-" + uuid4().hex[:12]
    with tempfile.TemporaryDirectory(prefix=project) as directory:
        root = Path(directory)
        (root / "probe.c").write_text("#include <unistd.h>\nint main(int argc, char **argv) { if (argc > 1) return 0; for (;;) pause(); }\n")
        execute(["gcc", "-static", "-O2", "-s", "-o", "probe", "probe.c"], root)
        manifest = fixture()
        node = manifest["target"]["nodeId"]
        (root / "Dockerfile").write_text(
            "FROM scratch\nCOPY probe /probe\n"
            "COPY build-info.json /usr/share/nginx/html/build-info.json\n"
            "COPY openmrs-distro.properties /openmrs/distribution/openmrs-distro.properties\n"
            f'LABEL org.sihsalus.node-id="{node}"\n'
            f'LABEL org.opencontainers.image.revision="{manifest["sources"]["frontend"]["commit"]}"\n'
            'CMD ["/probe"]\n'
            'HEALTHCHECK --interval=1s --timeout=1s CMD ["/probe", "check"]\n'
        )
        base = {"services": {name: {"image": "invalid.invalid/never:latest", "build": "./missing-build",
                                     "network_mode": "none"} for name in ("frontend", "gateway")}}
        (root / "base.json").write_text(json.dumps(base))
        command = ["docker", "compose", "--project-name", project, "--file", "base.json", "--file", "images.json"]
        tags = []
        image_ids = []
        try:
            for version in ("1.25.20", "1.25.21"):
                tag = f"{project}:{version}"
                tags.append(tag)
                (root / "build-info.json").write_text(json.dumps({"gitSha": manifest["sources"]["frontend"]["commit"]}))
                (root / "openmrs-distro.properties").write_text(f"content.sihsalus-content={version}\n")
                execute(["docker", "build", "--network", "none", "--tag", tag, "."], root)
                inspected = release.inspect_image(tag, root)
                assert inspected["node"] == node
                image_id = inspected["id"]
                assert release.matches(image_id, release.DIGEST)
                image_ids.append(image_id)
                info = json.loads(release.image_file(image_id, "/usr/share/nginx/html/build-info.json", root))
                assert info["gitSha"] == manifest["sources"]["frontend"]["commit"]
                properties = release.image_file(image_id, "/openmrs/distribution/openmrs-distro.properties", root)
                assert properties == f"content.sihsalus-content={version}\n"

            assert image_ids[0] != image_ids[1]
            # Initial deployment, update and rollback all resolve local IDs,
            # despite unusable mutable defaults and absent build contexts.
            for image_id in (image_ids[0], image_ids[1], image_ids[0]):
                for name in ("frontend", "gateway"):
                    manifest["services"][name] = {"image": image_id, "imageId": image_id}
                override = release.compose_override(manifest)
                override["services"] = {name: override["services"][name] for name in ("frontend", "gateway")}
                (root / "images.json").write_text(json.dumps(override))
                execute(command + ["up", "--detach", "--force-recreate", "--no-build", "--pull", "never", "--wait", "--wait-timeout", "30"], root)
                for name in ("frontend", "gateway"):
                    container = execute(command + ["ps", "--quiet", name], root).strip()
                    actual = execute(["docker", "inspect", container, "--format", "{{.Image}}"], root).strip()
                    assert actual == image_id
            print("PASS: real Docker metadata extraction and Compose local-image-ID update/rollback, without pulls or builds during up")
        finally:
            # Only this run's isolated containers/network/images; no host data,
            # mounted volumes, published ports, or daemon-wide cleanup.
            if (root / "images.json").exists():
                subprocess.run(command + ["down"], cwd=root, check=False, capture_output=True, timeout=60)
            for tag in tags:
                subprocess.run(["docker", "image", "rm", tag], cwd=root, check=False, capture_output=True, timeout=60)


if __name__ == "__main__":
    main()
