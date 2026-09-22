#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$ROOT_DIR/.github/workflows/build-backend.yml" <<'PY'
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from tempfile import TemporaryDirectory
import textwrap


workflow = Path(sys.argv[1]).read_text(encoding="utf-8")


def block(source, heading):
    matches = list(re.finditer(r"^      - " + re.escape(heading) + r"\n", source, re.M))
    if len(matches) != 1:
        raise AssertionError("Expected exactly one workflow step: " + heading)
    start = matches[0].start()
    end = re.search(r"^      - ", source[matches[0].end():], re.M)
    return source[start:matches[0].end() + end.start()] if end else source[start:]


def step(name, source=workflow):
    return block(source, "name: " + name)


def script(name):
    body = step(name).split("        run: |\n", 1)[1]
    return textwrap.dedent(body).strip() + "\n"


image_gates = [
    "Test published backend OCL token contract",
    "Verify packaged versions, owned release bytes and compiled protections",
    "Verify published O3 Forms bytes in backend image",
    "Verify required OMOD dependency compatibility with packaged Core",
    "Test published backend forced-password contract",
    "Test published backend Tomcat configuration directory permissions",
    "Scan immutable backend candidate",
]
other_gates = [
    "Validate published O3 Forms dependency contract",
    "Validate independently released REST and EMR API modules",
    "Test Tomcat rootless configuration directory contract",
    "Resolve pinned OpenMRS security baseline",
    "Scan pinned OpenMRS baseline",
    "Enforce backend vulnerability ratchet",
    "Validate current exception policy",
    "Install cosign",
    "Sign image",
]


def validate_structure(source):
    for name in image_gates + other_gates:
        body = step(name, source)
        assert "        if:" not in body, name + " must run in both modes"
        assert "continue-on-error" not in body, name + " must remain blocking"
    for name in image_gates + ["Produce backend Trivy evidence", "Sign image", "Publish verified release aliases"]:
        assert "${{ steps.image.outputs.digest }}" in step(name, source), name + " must use the resolved digest"
    attestation = step("Require attested and scanned backend digest", source)
    assert "!cancelled() && steps.image.outcome == 'success' && steps.image.outputs.digest != ''" in attestation
    assert "image: ghcr.io/sihsalus/sihsalus-backend@${{ steps.image.outputs.digest }}" in attestation
    assert "source: ${{ steps.request.outputs.source_sha }}" in attestation
    assert "continue-on-error" not in attestation
    assert source.index("name: Require attested and scanned backend digest") < source.index("name: Sign image")
    assert "run: bash scripts/security/promote-image.sh" in step("Publish verified release aliases", source)
    assert "PROMOTE_LATEST: ${{ github.ref == 'refs/heads/main' }}" in step("Publish verified release aliases", source)
    assert source.count("steps.build.outputs.digest") == 1
    assert "BUILD_DIGEST: ${{ steps.build.outputs.digest }}" in step("Resolve backend image for verification", source)
    assert "REUSE_DIGEST: ${{ steps.reuse.outputs.digest }}" in step("Resolve backend image for verification", source)
    assert "if:" not in step("Resolve backend image for verification", source)
    build = block(source, "uses: docker/build-push-action@v7")
    assert "if: steps.request.outputs.mode == 'build'" in build
    assert "cache-to: type=gha,scope=backend,mode=max,ignore-error=true" in build
    assert "continue-on-error" not in build
    assert "tags: ghcr.io/sihsalus/sihsalus-backend:candidate-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}" in build
    assert "SECURITY_REFRESH=${{ github.sha }}" in build
    assert "if: steps.request.outputs.mode == 'verify-existing'" in step("Verify existing immutable backend image", source)
    assert "if: steps.request.outputs.mode == 'verify-existing'" in step("Check out the existing image source", source)
    assert "if: steps.request.outputs.mode == 'build'" in step("Publish verified release aliases", source)
    assert "if: steps.request.outputs.mode == 'build'" in step("Make package public", source)
    assert "always() && steps.image.outcome == 'success' && steps.image.outputs.digest != ''" in step("Produce backend Trivy evidence", source)
    assert "always() && hashFiles('trivy-backend-results.sarif') != ''" in step("Upload backend Trivy evidence", source)
    checkout = block(source, "uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1")
    assert "ref: ${{ github.sha }}" in checkout
    assert "fetch-depth: ${{ steps.request.outputs.mode == 'verify-existing' && '0' || '1' }}" in checkout
    ordered = ["name: Validate backend workflow request", "uses: actions/checkout@", "name: Test backend workflow contract",
               "name: Check out the existing image source", "name: Restore current image security policy",
               "name: Validate current exception policy", "name: Validate published O3 Forms dependency contract",
               "uses: docker/login-action@"]
    positions = [source.index(value) for value in ordered]
    assert positions == sorted(positions), "Validate the workflow before checking out the image's source tests"
    assert "run: bash tests/backend/build-backend-config.sh" in step("Test backend workflow contract", source)


validate_structure(workflow)
mutations = {
    "skip reused-image gate": workflow.replace("      - name: " + image_gates[1] + "\n",
        "      - name: " + image_gates[1] + "\n        if: steps.request.outputs.mode == 'build'\n"),
    "scan a mutable alias": workflow.replace("image-ref: ghcr.io/sihsalus/sihsalus-backend@${{ steps.image.outputs.digest }}",
        "image-ref: ghcr.io/sihsalus/sihsalus-backend:latest", 1),
    "skip reuse SARIF": workflow.replace("steps.image.outcome == 'success'", "steps.build.outcome == 'success'"),
    "skip reused-image attestation": workflow.replace("!cancelled() && steps.image.outcome", "!cancelled() && steps.build.outcome"),
    "attest wrong source": workflow.replace("source: ${{ steps.request.outputs.source_sha }}", "source: ${{ github.sha }}"),
    "promote reuse": workflow.replace("if: steps.request.outputs.mode == 'build'",
        "if: github.ref == 'refs/heads/main'"),
    "publish reuse": workflow.replace("      - name: Make package public\n        if: steps.request.outputs.mode == 'build'",
        "      - name: Make package public"),
    "checkout mutable branch": workflow.replace("ref: ${{ github.sha }}", "ref: main"),
    "insufficient source history": workflow.replace("fetch-depth: ${{ steps.request.outputs.mode == 'verify-existing' && '0' || '1' }}", "fetch-depth: 1"),
}
for name, mutation in mutations.items():
    try:
        validate_structure(mutation)
    except AssertionError:
        continue
    raise AssertionError("Accepted workflow regression: " + name)
print("[OK] Shared gates, immutable digest consumers, release isolation and workflow/source checkout order")

with TemporaryDirectory(prefix="sihsalus-backend-workflow-") as temporary:
    directory = Path(temporary)
    output = directory / "output"
    summary = directory / "summary"
    base = dict(os.environ, GITHUB_REPOSITORY="sihsalus/sihsalus", GITHUB_EVENT_NAME="workflow_dispatch",
                GITHUB_REF="refs/heads/recovery", GITHUB_SHA="b" * 40, GITHUB_OUTPUT=str(output),
                GITHUB_STEP_SUMMARY=str(summary), MODE="verify-existing", SOURCE_SHA="a" * 40,
                IMAGE_DIGEST="sha256:" + "c" * 64, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)

    def execute(name, env, expected_ok, cwd=directory):
        output.write_text("")
        summary.write_text("")
        result = subprocess.run(["bash", "-c", script(name)], cwd=cwd, env=env, text=True, capture_output=True)
        assert (result.returncode == 0) == expected_ok, name + ": " + result.stdout + result.stderr
        if not expected_ok:
            assert output.read_text() == "", "Rejected requests must not publish usable outputs"
        return output.read_text()

    request_cases = [
        ("manual existing image", {}, True),
        ("main push build", dict(MODE="build", SOURCE_SHA="", IMAGE_DIGEST="", GITHUB_EVENT_NAME="push", GITHUB_REF="refs/heads/main"), True),
        ("manual build defaults", dict(MODE="build", SOURCE_SHA="", IMAGE_DIGEST=""), True),
        ("fork", dict(GITHUB_REPOSITORY="someone/sihsalus"), False),
        ("fork build", dict(GITHUB_REPOSITORY="someone/sihsalus", MODE="build", SOURCE_SHA="", IMAGE_DIGEST=""), False),
        ("main reuse", dict(GITHUB_REF="refs/heads/main"), False),
        ("tag dispatch", dict(GITHUB_REF="refs/tags/recovery"), False),
        ("push reuse", dict(GITHUB_EVENT_NAME="push"), False),
        ("pull request reuse", dict(GITHUB_EVENT_NAME="pull_request"), False),
        ("missing both inputs", dict(SOURCE_SHA="", IMAGE_DIGEST=""), False),
        ("missing source", dict(SOURCE_SHA=""), False),
        ("missing digest", dict(IMAGE_DIGEST=""), False),
        ("inputs without opt-in", dict(MODE="build"), False),
        ("short source", dict(SOURCE_SHA="a" * 7), False),
        ("uppercase source", dict(SOURCE_SHA="A" * 40), False),
        ("mutable source", dict(SOURCE_SHA="main"), False),
        ("source revision expression", dict(SOURCE_SHA="a" * 40 + "^"), False),
        ("source output injection", dict(SOURCE_SHA="a" * 40 + "\nmode=build"), False),
        ("mutable image", dict(IMAGE_DIGEST="latest"), False),
        ("short digest", dict(IMAGE_DIGEST="sha256:" + "c" * 63), False),
        ("uppercase digest", dict(IMAGE_DIGEST="sha256:" + "C" * 64), False),
        ("digest output injection", dict(IMAGE_DIGEST="sha256:" + "c" * 64 + "\nmode=build"), False),
        ("unknown mode", dict(MODE="other"), False),
    ]
    for name, changes, valid in request_cases:
        resolved = execute("Validate backend workflow request", dict(base, **changes), valid)
        if valid:
            env = dict(base, **changes)
            source = env["GITHUB_SHA"] if env["MODE"] == "build" else env["SOURCE_SHA"]
            assert resolved == "mode=" + env["MODE"] + "\nsource_sha=" + source + "\n", name
    print(f"[OK] {len(request_cases)} executable request guards, including main/fork/mutable-reference rejection")

    repository = directory / "repository"
    repository.mkdir()

    def git(*args):
        return subprocess.check_output(["git", *args], cwd=repository, env=base, text=True, stderr=subprocess.DEVNULL).strip()

    git("init", "--quiet")
    git("config", "user.name", "Workflow contract test")
    git("config", "user.email", "workflow-test@example.invalid")
    (repository / "source-lock").write_text("image source")
    git("add", "source-lock")
    git("commit", "--quiet", "-m", "image source")
    source_sha = git("rev-parse", "HEAD")
    (repository / "source-lock").write_text("workflow source")
    security_paths = [".github/actions/check-image/action.yml", "scripts/security/image-policy.py",
                      "scripts/security/image-tool.py", "scripts/security/scan-image.sh", "security/image-exceptions.json"]
    for name in security_paths:
        target = repository / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("current reviewed policy")
    git("add", ".")
    git("commit", "--quiet", "-m", "workflow source")
    workflow_sha = git("rev-parse", "HEAD")
    unrelated = git("commit-tree", git("write-tree"), "-m", "unrelated source")
    git("commit", "--quiet", "--allow-empty", "-m", "future descendant")
    descendant = git("rev-parse", "HEAD")
    for candidate, valid in [(source_sha, True), (workflow_sha, True), (unrelated, False), (descendant, False), ("0" * 40, False)]:
        git("checkout", "--quiet", "--detach", workflow_sha)
        execute("Check out the existing image source", dict(base, SOURCE_SHA=candidate, GITHUB_SHA=workflow_sha), valid, repository)
        assert git("rev-parse", "HEAD") == (candidate if valid else workflow_sha)
        if candidate == source_sha:
            assert (repository / "source-lock").read_text() == "image source"
    print("[OK] Exact source checkout accepts ancestors and rejects unrelated, future or missing commits")
    execute("Check out the existing image source", dict(base, SOURCE_SHA=source_sha, GITHUB_SHA=workflow_sha), True, repository)
    execute("Restore current image security policy", dict(base, GITHUB_SHA=workflow_sha), True, repository)
    assert git("rev-parse", "HEAD") == source_sha
    assert (repository / "source-lock").read_text() == "image source"
    for name in security_paths:
        assert (repository / name).read_text() == "current reviewed policy"
    print("[OK] Historical image contracts retain current security action, scanner and exception policy")

    executable = directory / "bin"
    executable.mkdir()
    docker = executable / "docker"
    calls = directory / "docker-calls"
    docker.write_text("""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['DOCKER_CALLS'], 'a') as log:
    log.write(json.dumps(args) + '\\n')
expected = 'ghcr.io/sihsalus/sihsalus-backend@' + os.environ['IMAGE_DIGEST']
if args == ['buildx', 'imagetools', 'inspect', expected, '--format', '{{.Manifest.Digest}}']:
    print(os.environ['MANIFEST_DIGEST'])
elif args == ['pull', '--platform', 'linux/amd64', expected]:
    sys.exit(int(os.environ.get('PULL_STATUS', '0')))
elif args == ['image', 'inspect', expected, '--format', '{{.Os}}/{{.Architecture}}']:
    print(os.environ['IMAGE_PLATFORM'])
elif args == ['image', 'inspect', expected, '--format', '{{index .Config.Labels "org.opencontainers.image.revision"}}']:
    print(os.environ['IMAGE_REVISION'])
else:
    sys.exit('Unexpected Docker command: ' + repr(args))
""")
    docker.chmod(0o755)
    image_env = dict(base, PATH=str(executable) + os.pathsep + os.environ["PATH"], DOCKER_CALLS=str(calls),
                     MANIFEST_DIGEST=base["IMAGE_DIGEST"], IMAGE_PLATFORM="linux/amd64", IMAGE_REVISION=base["SOURCE_SHA"])
    image_cases = [({}, True), (dict(MANIFEST_DIGEST="sha256:" + "d" * 64), False),
                   (dict(IMAGE_PLATFORM="linux/arm64"), False), (dict(IMAGE_PLATFORM="windows/amd64"), False),
                   (dict(IMAGE_REVISION="d" * 40), False), (dict(IMAGE_REVISION=""), False), (dict(PULL_STATUS="1"), False)]
    for changes, valid in image_cases:
        calls.write_text("")
        resolved = execute("Verify existing immutable backend image", dict(image_env, **changes), valid)
        if valid:
            assert resolved == "digest=" + base["IMAGE_DIGEST"] + "\n"
            assert len(calls.read_text().splitlines()) == 4
    print("[OK] Immutable manifest, linux/amd64 pull and image source revision checks; Docker was stubbed")

    build_digest, reuse_digest = "sha256:" + "1" * 64, "sha256:" + "2" * 64
    for mode, built, reused, expected in [
        ("build", build_digest, reuse_digest, build_digest),
        ("verify-existing", build_digest, reuse_digest, reuse_digest),
        ("build", "", reuse_digest, None),
        ("verify-existing", build_digest, "", None),
        ("verify-existing", build_digest, "latest", None),
    ]:
        resolved = execute("Resolve backend image for verification", dict(base, MODE=mode, BUILD_DIGEST=built, REUSE_DIGEST=reused), expected is not None)
        if expected:
            assert resolved == "digest=" + expected + "\n"
            assert "Image source commit: " + base["SOURCE_SHA"] in summary.read_text()
            assert "Workflow commit: " + base["GITHUB_SHA"] in summary.read_text()
    print("[OK] Common digest resolution fails closed and distinguishes image source from workflow commit")
PY
