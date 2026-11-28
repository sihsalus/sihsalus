#!/usr/bin/env python3
"""Verify a QLTY backend that became ready after Compose timed out. Default: inspect only."""

import argparse
from datetime import datetime, timezone
import hashlib
from importlib import util
import os
from pathlib import Path
import re
import subprocess
import sys
from tempfile import TemporaryDirectory
from uuid import uuid4

import deploy

release = deploy.releases
spec = util.spec_from_file_location("qlty", deploy.DIRECTORY / "deploy-qlty-backend.py")
qlty = util.module_from_spec(spec)
spec.loader.exec_module(qlty)
UUID = r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}"
HASH = r"[0-9a-f]{64}"
MAC_PATH = Path("/sys/class/net/ens160/address")


def regular(path):
    release.require(path.is_file() and path.resolve() == path, "Missing or redirected recovery evidence")
    return path


def file_hash(path):
    digest = hashlib.sha256()
    with regular(path).open("rb") as data:
        for chunk in iter(lambda: data.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def verify_backup(root, run_token, backup, previous, prior, failed):
    run = root / ".redeploy-runs" / run_token
    release.require(regular(run / "status").read_text().strip() == "1", "Remote run did not exit with the expected failure")
    prefix = "OpenMRS database backup verified by isolated restore: "
    timeout_prefix = "application not healthy after "
    required = [prefix + backup, "Container sihsalus-backend Recreated", "Container sihsalus-backend Started",
                "Container sihsalus-backend Waiting", timeout_prefix,
                "[deploy-qlty-backend] Failed: Redeploy failed; use the retained previous manifest for recovery"]
    lines = []
    with regular(run / "redeploy.log").open() as stream:
        for line in map(str.strip, stream):
            if line.startswith(timeout_prefix):
                release.require(line in (timeout_prefix + "30m0s", timeout_prefix + "3h0m0s"),
                                "Remote run has an unexpected Compose timeout")
                lines.append(timeout_prefix)
            elif line.startswith(prefix) or line in required:
                lines.append(line)
    release.require([line for line in lines if line.startswith(prefix)] == [prefix + backup], "Remote backup receipt differs")
    cursor = iter(lines)
    release.require(lines.count(timeout_prefix) == 1 and all(any(line == step for line in cursor) for step in required),
                    "Remote run lacks a unique backend timeout sequence")
    source = Path.home() / ".local/share/sihsalus/backups/qlty-backend-update" / backup
    receipt = regular(source / "verification.txt")
    release.require(regular(prior / "result.json").stat().st_mtime_ns <= receipt.stat().st_mtime_ns <=
                    regular(failed / "target.json").stat().st_mtime_ns <=
                    regular(failed / "result.json").stat().st_mtime_ns <= (run / "status").stat().st_mtime_ns,
                    "Backup and remote result do not bracket the reviewed deployment")
    records = receipt.read_text().splitlines()
    key_sources = {"key=BACKUP_ENCRYPTION_PASSWORD", "key=~/.sihsalus-backup-keys/qlty-backend-update.key"}
    expected = {"timestamp=" + backup.split("-")[1], "scope=openmrs-database",
                "source_image=" + previous["services"]["db"]["imageId"],
                "checks=sha256,decryption,isolated-restore,table-list,mariadb-check"}
    release.require(len(records) == 5 and expected <= set(records) and key_sources.intersection(records),
                    "Backup receipt does not match the retained MariaDB and isolated restore")
    checksums = regular(source / "SHA256SUMS").read_text()
    match = re.fullmatch(r"([a-f0-9]{64})  (dump_\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d\.sql\.gz\.enc)\n", checksums)
    release.require(match and file_hash(source / match[2]) == match[1] and (source / match[2]).stat().st_size > 0,
                    "Encrypted backup checksum differs")
    return {"id": backup, "encryptedSha256": match[1], "receiptSha256": file_hash(receipt)}


def verify_recovery_images(root, previous):
    state = root / ".env.release-state"
    digest = release.manifest_digest(previous)
    release.require(release.read_json(regular(state / (digest + ".json"))) == previous and
                    release.read_json(regular(state / (digest + ".compose.json"))) == release.compose_override(previous),
                    "Previous recovery selection differs")
    release.verify_images(previous, root)
    ids = {name: item["imageId"] for name, item in previous["services"].items()}
    ids["source-frontend"] = release.inspect_image(previous["sources"]["frontend"]["image"], root)["id"]
    for name, image_id in ids.items():
        tag = f"sihsalus-release-retained:{digest[:48]}-{name}"
        release.require(release.inspect_image(tag, root)["id"] == image_id, "Previous recovery image tag differs")


def backend_instance(root, failed_directory):
    template = '{{.Id}} {{.Image}} {{.State.StartedAt}} {{.RestartCount}}'
    line = release.run(["docker", "inspect", "sihsalus-backend", "--format", template], root=root).strip()
    identifier, image_id, started, restarts = line.split()
    release.require(release.matches(identifier, HASH) and release.matches(image_id, release.DIGEST) and restarts == "0",
                    "Backend identity changed after the timed-out update")
    timestamp = re.fullmatch(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?Z", started)
    release.require(timestamp, "Invalid Docker startup timestamp")
    seconds = int(datetime.fromisoformat(timestamp[1]).replace(tzinfo=timezone.utc).timestamp())
    started_ns = seconds * 1_000_000_000 + int((timestamp[2] or "").ljust(9, "0"))
    release.require(regular(failed_directory / "target.json").stat().st_mtime_ns <= started_ns <=
                    regular(failed_directory / "result.json").stat().st_mtime_ns,
                    "Backend did not start during the reviewed run")
    return {"containerId": identifier, "imageId": image_id, "startedAt": started}


def finalize(root, attempt, previous, target, sha, digest, run_token, backup, apply=False):
    for value, pattern in [(attempt, UUID), (previous, HASH), (target, HASH), (sha, release.SHA), (digest, release.DIGEST),
                           (run_token, r"[1-9][0-9]*-[1-9][0-9]*-backend-qlty"),
                           (backup, r"verified-\d{8}T\d{6}Z-[0-9a-f]{8}")]:
        release.require(release.matches(value, pattern), "Invalid recovery identifier")
    root = deploy.checked_root(root)
    release.require(MAC_PATH.read_text().strip() == "00:0c:29:1c:f7:78", "Wrong QLTY network interface")
    with release.release_lock(root) as state:
        selection = state / (target + ".json")
        release.require(deploy.env_value(root, "SIHSALUS_RELEASE_MANIFEST") == str(regular(selection)) and
                        deploy.env_value(root, "SIHSALUS_NODE_ID") == qlty.QLTY_NODE and
                        deploy.env_value(root, "DEPLOYMENT_ENV") == "qlty", "Wrong host or selected release")
        current = deploy.current_release(root)
        release.require(current["target"] == {"environment": "qlty", "nodeId": qlty.QLTY_NODE} and
                        release.manifest_digest(current) == target, "Wrong QLTY release")
        attempts = [p for p in state.iterdir() if release.matches(p.name, UUID)]
        attempts.sort(key=lambda p: ((p / "result.json") if (p / "result.json").is_file() else p).stat().st_mtime_ns,
                      reverse=True)
        release.require(len(attempts) >= 2, "A prior verified deployment is required")
        latest = release.read_json(regular(attempts[0] / "result.json"))
        replay = latest.get("operation") == "verify-recovery"
        if replay:
            saved = attempts.pop(0)
        failed = state / attempt
        release.require(len(attempts) >= 2 and attempts[0] == failed, "A newer or unrelated deployment exists")
        prior = attempts[1]
        before = release.validate_manifest(release.read_json(regular(failed / "previous.json")))
        prior_result = release.read_json(regular(prior / "result.json"))
        release.require(release.read_json(regular(failed / "result.json")) == {
            "operation": "deploy", "previous": previous, "target": target, "status": "failed-or-interrupted"}
            and release.manifest_digest(before) == previous and release.read_json(regular(failed / "target.json")) == current
            and prior_result["status"] == "verified" and prior_result["target"] == previous and
            release.manifest_digest(release.read_json(regular(prior / "previous.json"))) == prior_result["previous"] and
            release.read_json(regular(prior / "target.json")) == before, "Deployment journals do not match the approved edge")
        marker = release.run(["bash", "-c", 'source "$1"; read_env_value SIHSALUS_RELEASE_MANIFEST "$2"',
                              "env-reader", str(deploy.DIRECTORY / "env.sh"), str(regular(failed / "before.env"))], root=root)
        release.require(marker.strip() == str(state / (previous + ".json")), "Previous selection snapshot differs")
        release.verify_transition(current, before)
        backend = {"commit": sha, "image": f"{release.BACKEND_REPOSITORY}:sha-{sha}@{digest}"}
        release.require(before["sources"]["backend"] != backend and current["sources"] == dict(
            before["sources"], backend=backend, contentVersion=current["sources"]["contentVersion"]) and
            current["services"] == dict(before["services"], backend=current["services"]["backend"]) and
            current["services"]["backend"]["imageId"] != before["services"]["backend"]["imageId"],
            "Recovery must cover only the approved backend change")
        verify_recovery_images(root, before)
        evidence = verify_backup(root, run_token, backup, before, prior, failed)
        release.verify_images(current, root)
        release.require(deploy.source_image("backend", backend["image"], root) == backend, "Backend registry digest differs")
        instance = backend_instance(root, failed)
        release.require(instance["imageId"] == current["services"]["backend"]["imageId"], "Running backend differs")
        release.require(os.environ.get("EXTERNAL_VERIFY_SAMPLE_COUNT", "12") == "12", "Require twelve public samples")
        release.verify_runtime(current, root)
        deploy.health(current, root, ["frontend", "backend"])
        deploy.verify_external(current, root, qlty.QLTY_URL)
        release.verify_selected_compose(current, root, root / ".env", selection)
        release.verify_runtime(current, root)
        deploy.health(current, root, ["frontend", "backend"])
        release.require(backend_instance(root, failed) == instance, "Backend changed during public checks")
        result = {"operation": "verify-recovery", "status": "verified", "previous": previous, "target": target,
                  "attempt": attempt, "priorAttempt": prior.name, "remoteRun": run_token, "backup": evidence, "backend": instance}
        if replay:
            release.require({k: v for k, v in latest.items() if k != "verifiedAt"} == result and
                            release.read_json(regular(saved / "previous.json")) == before and
                            release.read_json(regular(saved / "target.json")) == current, "Recovery record differs")
            return "already verified " + saved.name
        if not apply:
            return "ready to record"
        result["verifiedAt"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        destination = state / str(uuid4())
        with TemporaryDirectory(prefix="staging-recovery-", dir=state) as temporary:
            journal = Path(temporary) / "journal"
            journal.mkdir(mode=0o700)
            for name, data in [("previous", before), ("target", current), ("result", result)]:
                release.write_new(journal / (name + ".json"), data)
            release.require((journal / "result.json").stat().st_mtime_ns > (failed / "result.json").stat().st_mtime_ns,
                            "Recovery journal timestamp precedes the failed attempt")
            release.require(not destination.exists(), "Recovery journal identifier already exists")
            sync_directory(journal)
            journal.rename(destination)
            sync_directory(state)
        return "verified " + destination.name


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("attempt", "previous", "target", "sha", "digest", "run-token", "backup"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--apply", action="store_true", help="Append an independently verified recovery journal")
    try:
        print(finalize(Path.cwd(), **vars(parser.parse_args())))
    except release.ManifestError as error:
        sys.exit(str(error))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        sys.exit("Failed to verify recovery evidence")
