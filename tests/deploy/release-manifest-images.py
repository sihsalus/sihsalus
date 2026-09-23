#!/usr/bin/env python3
"""Exercise image metadata with real Docker templates; never start containers."""

import importlib.util
import json
from pathlib import Path
import subprocess
from uuid import uuid4


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_manifest", ROOT / "scripts/deploy/release-manifest.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


def main():
    references = []
    prefix = f"sihsalus-release-inspect-test:{uuid4().hex}"
    secret = "SYNTHETIC_VALUE_MUST_NOT_BE_RETAINED"
    source = "a" * 40
    node = "11111111-1111-4111-8111-111111111111"
    try:
        for variant, labels in (
            ("unlabeled", ""),
            ("unrelated-label", 'LABEL maintainer="synthetic fixture"\n'),
            ("labeled", f'LABEL org.opencontainers.image.revision="{source}" org.sihsalus.node-id="{node}"\n'),
        ):
            reference = f"{prefix}-{variant}"
            dockerfile = f'FROM scratch\nENV SYNTHETIC_SECRET={secret}\n{labels}CMD ["/unused"]\n'
            subprocess.run(["docker", "build", "--quiet", "--tag", reference, "-"],
                           input=dockerfile, text=True, check=True, stdout=subprocess.DEVNULL)
            references.append(reference)
            metadata = release.inspect_image(reference, ROOT)
            assert release.matches(metadata["id"], release.DIGEST)
            assert metadata["os"] == "linux"
            assert metadata["revision"] == (source if variant == "labeled" else None)
            assert metadata["node"] == (node if variant == "labeled" else None)
            assert secret not in json.dumps(metadata)
            assert set(metadata) == {"id", "os", "arch", "digests", "revision", "node"}
            print(f"PASS: {variant} image metadata; no container started or environment retained")
    finally:
        for reference in references:
            subprocess.run(["docker", "image", "rm", reference], check=True, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
