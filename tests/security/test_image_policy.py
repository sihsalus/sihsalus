"""Synthetic policy and promotion regressions; no network or Docker daemon."""

from copy import deepcopy
from datetime import date, datetime, timedelta, timezone
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("image_policy", ROOT / "scripts/security/image-policy.py")
policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(policy)
TODAY = date(2026, 9, 21)
NOW = datetime(2026, 9, 21, 12, tzinfo=timezone.utc)
REPOSITORY = "ghcr.io/sihsalus/sihsalus-gateway"
IMAGE = REPOSITORY + "@sha256:" + "0" * 64
SOURCE = "a" * 40
EMPTY_POLICY = {"schemaVersion": 1, "exceptions": []}
REPORT_ONLY_POLICY = {**EMPTY_POLICY, "vulnerabilityMode": "report-only"}
FINDING = {"VulnerabilityID": "CVE-2026-12345", "PkgName": "synthetic-library", "InstalledVersion": "1.0.0",
           "FixedVersion": "1.0.1", "Severity": "HIGH"}
SECRET = "SYNTHETIC_CREDENTIAL_MUST_NOT_BE_RETAINED"


def fixture():
    descriptors, reports, sboms = [], {}, {}
    for number, platform in enumerate(("linux/amd64", "linux/arm64"), 1):
        digest = "sha256:" + str(number) * 64
        descriptors.append({"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": digest, "size": 10,
                            "platform": {"os": "linux", "architecture": platform.split("/")[1]}})
        descriptors.append({"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": "sha256:" + str(number + 2) * 64,
                            "size": 10, "platform": {"os": "unknown", "architecture": "unknown"},
                            "annotations": {"vnd.docker.reference.type": "attestation-manifest", "vnd.docker.reference.digest": digest}})
        reports[platform] = {
            "SchemaVersion": 2, "ArtifactType": "container_image", "ArtifactName": REPOSITORY + "@" + digest,
            "Metadata": {"ImageID": "sha256:" + "9" * 64,
                         "ImageConfig": {"os": "linux", "architecture": platform.split("/")[1],
                                         "config": {"Env": ["TOKEN=" + SECRET], "Labels": {"org.opencontainers.image.revision": SOURCE}}}},
            "Results": [{"Class": "os-pkgs", "Type": "alpine", "Target": SECRET, "Vulnerabilities": []}],
        }
        sboms[platform] = {"SPDX": {"spdxVersion": "SPDX-2.3", "SPDXID": "SPDXRef-DOCUMENT",
                                     "documentNamespace": "https://test.invalid/sbom/" + platform,
                                     "packages": [{"name": "synthetic-library", "versionInfo": "1.0.0", "comment": SECRET}]}}
    index = {"schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json", "manifests": descriptors}
    return index, sboms, reports


def exception(**changes):
    entry = {"id": "synthetic-accepted-risk", "repository": REPOSITORY, "platform": "linux/amd64",
             "vulnerabilityId": FINDING["VulnerabilityID"], "packageName": FINDING["PkgName"],
             "installedVersion": FINDING["InstalledVersion"], "class": "os-pkgs", "type": "alpine", "severity": "HIGH",
             "owner": "@synthetic-owner", "issue": "https://github.com/sihsalus/sihsalus/issues/177",
             "rationale": "Synthetic exception fixture; not an accepted production risk.",
             "createdOn": "2026-09-20", "expiresOn": "2026-09-27"}
    entry.update(changes)
    return entry


def evaluate(index=None, sbom=None, reports=None, exceptions=None):
    defaults = fixture()
    return policy.evaluate(IMAGE, SOURCE, "0.74.0", index if index is not None else defaults[0],
                           sbom if sbom is not None else defaults[1], reports if reports is not None else defaults[2],
                           exceptions if exceptions is not None else EMPTY_POLICY, today=TODAY)


class PolicyContract(unittest.TestCase):
    def test_report_only_retains_findings_and_distinguishes_them_from_clean_images(self):
        _, _, reports = fixture()
        for report in reports.values():
            report["Results"][0]["Vulnerabilities"] = [{**FINDING, "Severity": "CRITICAL", "FixedVersion": ""}]
        evidence = evaluate(reports=reports, exceptions=REPORT_ONLY_POLICY)
        self.assertEqual(evidence["decision"], "warn")
        self.assertEqual(evidence["blockedFindings"], 2)
        self.assertTrue(all(p["findings"][0]["decision"] == "warn" for p in evidence["platforms"]))
        self.assertNotIn(SECRET, json.dumps(evidence))
        self.assertEqual(evaluate(exceptions=REPORT_ONLY_POLICY)["decision"], "pass")

    def test_vulnerability_mode_is_explicit_and_validated(self):
        self.assertEqual(policy.vulnerability_mode(policy.validate_policy(EMPTY_POLICY)), "enforce")
        for mode in (None, False, "off", "report", "", []):
            with self.subTest(mode=mode), self.assertRaises(policy.PolicyError):
                policy.validate_policy({**EMPTY_POLICY, "vulnerabilityMode": mode})

    def test_cli_report_only_succeeds_with_warnings_but_scan_errors_still_fail(self):
        index, sbom, reports = fixture()
        reports["linux/amd64"]["Results"][0]["Vulnerabilities"] = [FINDING]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, value in {"index": index, "sbom": sbom, "policy": REPORT_ONLY_POLICY,
                                **{key.replace("/", "-"): report for key, report in reports.items()}}.items():
                (root / (name + ".json")).write_text(json.dumps(value))
            command = [sys.executable, str(ROOT / "scripts/security/image-policy.py"), "evaluate",
                       "--image", IMAGE, "--source", SOURCE, "--scanner", "0.74.0", "--reports", str(root),
                       "--index", str(root / "index.json"), "--sbom", str(root / "sbom.json"),
                       "--policy", str(root / "policy.json"), "--output", str(root / "evidence.json")]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("::warning::", result.stdout)
            self.assertEqual(json.loads((root / "evidence.json").read_text())["blockedFindings"], 1)
            (root / "evidence.json").unlink()
            (root / "linux-arm64.json").unlink()
            failed = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertFalse((root / "evidence.json").exists())

    def test_report_only_still_requires_complete_and_matching_scan_evidence(self):
        for missing in ("scan", "sbom", "attestation", "source", "malformed"):
            index, sbom, reports = fixture()
            if missing == "scan":
                reports.pop("linux/arm64")
            elif missing == "sbom":
                sbom.pop("linux/arm64")
            elif missing == "attestation":
                index["manifests"].pop()
            elif missing == "source":
                reports["linux/arm64"]["Metadata"]["ImageConfig"]["config"]["Labels"].clear()
            else:
                reports["linux/arm64"] = {}
            with self.subTest(missing=missing), self.assertRaises(policy.PolicyError):
                evaluate(index, sbom, reports, exceptions=REPORT_ONLY_POLICY)

    def test_clean_multiarch_image_retains_only_safe_evidence(self):
        evidence = evaluate()
        self.assertEqual(evidence["decision"], "pass")
        self.assertEqual(len(evidence["platforms"]), 2)
        self.assertEqual({entry["platform"] for entry in evidence["platforms"]}, {"linux/amd64", "linux/arm64"})
        self.assertNotIn(SECRET, json.dumps(evidence))
        self.assertNotIn("ImageConfig", json.dumps(evidence))
        self.assertNotIn("Target", json.dumps(evidence))
        self.assertTrue(all(entry["sbom"]["packageCount"] == 1 for entry in evidence["platforms"]))

    def test_high_and_critical_findings_block_even_without_a_fix(self):
        for severity in ("HIGH", "CRITICAL"):
            for fixed in ("", "1.0.1"):
                with self.subTest(severity=severity, fixed=fixed):
                    _, _, reports = fixture()
                    reports["linux/arm64"]["Results"][0]["Vulnerabilities"] = [{**FINDING, "Severity": severity, "FixedVersion": fixed}]
                    evidence = evaluate(reports=reports)
                    self.assertEqual(evidence["decision"], "block")
                    self.assertEqual(evidence["blockedFindings"], 1)

    def test_duplicate_package_paths_do_not_duplicate_risk(self):
        _, _, reports = fixture()
        reports["linux/amd64"]["Results"][0]["Vulnerabilities"] = [FINDING, FINDING]
        self.assertEqual(evaluate(reports=reports)["blockedFindings"], 1)

    def test_valid_exception_is_explicit_and_narrow(self):
        _, _, reports = fixture()
        for report in reports.values():
            report["Results"][0]["Vulnerabilities"] = [deepcopy(FINDING)]
        evidence = evaluate(reports=reports, exceptions={"schemaVersion": 1, "exceptions": [exception()]})
        self.assertEqual(evidence["decision"], "block")
        self.assertEqual(evidence["blockedFindings"], 1)
        self.assertEqual(evidence["platforms"][0]["findings"][0]["decision"], "exception")
        self.assertEqual(evidence["platforms"][1]["findings"][0]["decision"], "block")

    def test_exception_does_not_cover_another_version_ecosystem_or_severity(self):
        for changes in ({"InstalledVersion": "2.0.0"}, {"Severity": "CRITICAL"}, {"VulnerabilityID": "CVE-2026-54321"}):
            with self.subTest(changes=changes):
                _, _, reports = fixture()
                reports["linux/amd64"]["Results"][0]["Vulnerabilities"] = [{**FINDING, **changes}]
                self.assertEqual(evaluate(reports=reports, exceptions={"schemaVersion": 1, "exceptions": [exception()]})["decision"], "block")
        _, _, reports = fixture()
        reports["linux/amd64"]["Results"][0].update(Type="debian", Vulnerabilities=[FINDING])
        self.assertEqual(evaluate(reports=reports, exceptions={"schemaVersion": 1, "exceptions": [exception()]})["decision"], "block")

    def test_missing_expired_future_or_permanent_exception_data_is_rejected(self):
        variants = [exception(expiresOn="2026-09-20"), exception(createdOn="2026-09-22"),
                    exception(expiresOn="2027-01-01"), exception(owner=""), exception(rationale="temporary"),
                    exception(issue="https://example.invalid/approval"), exception(platform="*"),
                    exception(installedVersion="*"), exception(expiresOn="2026-02-30")]
        missing = exception()
        missing.pop("owner")
        variants.append(missing)
        for entry in variants:
            with self.subTest(entry=entry):
                with self.assertRaises(policy.PolicyError):
                    policy.validate_policy({"schemaVersion": 1, "exceptions": [entry]}, TODAY)

    def test_duplicate_or_additional_exception_fields_fail_closed(self):
        for entries in ([exception(), exception()], [exception(password=SECRET)], [exception(), exception(id="another-id")]):
            with self.assertRaises(policy.PolicyError):
                policy.validate_policy({"schemaVersion": 1, "exceptions": entries}, TODAY)

    def test_expiration_is_inclusive_in_utc_and_fails_the_next_day(self):
        value = {"schemaVersion": 1, "exceptions": [exception(expiresOn="2026-09-21")]}
        policy.validate_policy(value, TODAY)
        with self.assertRaises(policy.PolicyError):
            policy.validate_policy(value, TODAY + timedelta(days=1))

    def test_missing_platform_scan_sbom_or_attestation_is_rejected(self):
        for kind in ("scan", "sbom", "attestation"):
            with self.subTest(kind=kind):
                index, sbom, reports = fixture()
                if kind == "scan":
                    reports.pop("linux/arm64")
                elif kind == "sbom":
                    sbom.pop("linux/arm64")
                else:
                    index["manifests"].pop()
                with self.assertRaises(policy.PolicyError):
                    evaluate(index, sbom, reports)

    def test_index_cannot_hide_unknown_or_duplicate_executable_architectures(self):
        mutations = [lambda i: i["manifests"][2]["platform"].update(architecture="amd64"),
                     lambda i: i["manifests"][2]["platform"].update(architecture="s390x"),
                     lambda i: i["manifests"][1]["annotations"].clear(),
                     lambda i: i["manifests"][1]["annotations"].update({"vnd.docker.reference.digest": "sha256:" + "8" * 64})]
        for change in mutations:
            index, _, _ = fixture()
            change(index)
            with self.assertRaises(policy.PolicyError):
                evaluate(index=index)

    def test_scan_digest_and_architecture_must_match_the_index(self):
        for kind in ("subject", "arch", "empty-os-scan", "image-id", "source"):
            with self.subTest(kind=kind):
                _, _, reports = fixture()
                report = reports["linux/arm64"]
                if kind == "subject":
                    report["ArtifactName"] = REPOSITORY + ":latest"
                elif kind == "arch":
                    report["Metadata"]["ImageConfig"]["architecture"] = "amd64"
                elif kind == "image-id":
                    report["Metadata"]["ImageID"] = "unknown"
                elif kind == "source":
                    report["Metadata"]["ImageConfig"]["config"]["Labels"]["org.opencontainers.image.revision"] = "b" * 40
                else:
                    report["Results"] = []
                with self.assertRaises(policy.PolicyError):
                    evaluate(reports=reports)

    def test_single_platform_buildx_sbom_shape_is_supported(self):
        index, sbom, reports = fixture()
        index["manifests"] = index["manifests"][:2]
        reports.pop("linux/arm64")
        self.assertEqual(evaluate(index, sbom["linux/amd64"], reports)["decision"], "pass")

    def test_secret_scans_and_unstructured_vulnerability_details_are_not_retained(self):
        _, _, reports = fixture()
        report = reports["linux/amd64"]
        report["Results"][0]["Vulnerabilities"] = [{**FINDING, "Description": SECRET, "Title": SECRET, "References": [SECRET]}]
        self.assertNotIn(SECRET, json.dumps(evaluate(reports=reports)))
        report["Results"][0]["Secrets"] = [{"Match": SECRET}]
        with self.assertRaises(policy.PolicyError) as caught:
            evaluate(reports=reports)
        self.assertNotIn(SECRET, str(caught.exception))

    def test_manifest_tag_and_malformed_report_cannot_look_like_a_clean_scan(self):
        with self.assertRaises(policy.PolicyError):
            policy.image_repository(REPOSITORY + ":latest")
        _, _, reports = fixture()
        reports["linux/amd64"] = {}
        with self.assertRaises(policy.PolicyError):
            evaluate(reports=reports)

    def test_duplicate_json_and_evidence_overwrite_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            path.write_text('{"Results":[],"Results":[]}')
            with self.assertRaises(policy.PolicyError):
                policy.read_json(path)
            with self.assertRaises(FileExistsError):
                policy.write_evidence(path, evaluate())


class PromotionContract(unittest.TestCase):
    def test_report_only_allows_current_warning_evidence_and_reenforcement_rejects_it(self):
        _, _, reports = fixture()
        reports["linux/amd64"]["Results"][0]["Vulnerabilities"] = [FINDING]
        value = evaluate(reports=reports, exceptions=REPORT_ONLY_POLICY)
        value["scannedAt"] = NOW.strftime("%Y-%m-%dT%H:%M:%SZ")
        self.assertEqual(policy.validate_promotion(value, IMAGE, SOURCE, REPORT_ONLY_POLICY, NOW), value)
        with self.assertRaises(policy.PolicyError):
            policy.validate_promotion(value, IMAGE, SOURCE, EMPTY_POLICY, NOW)
        mutations = [lambda e: e.update(blockedFindings=0), lambda e: e.update(decision="pass"),
                     lambda e: e["platforms"][0].update(findings=[]),
                     lambda e: e["platforms"][0]["findings"][0].update(severity="LOW"),
                     lambda e: e["platforms"][0].pop("sbom"),
                     lambda e: e.update(scannedAt="2026-09-19T12:00:00Z"),
                     lambda e: e.update(sourceCommit="b" * 40)]
        for mutate in mutations:
            candidate = deepcopy(value)
            mutate(candidate)
            with self.assertRaises(policy.PolicyError):
                policy.validate_promotion(candidate, IMAGE, SOURCE, REPORT_ONLY_POLICY, NOW)

    def evidence(self):
        value = evaluate()
        value["scannedAt"] = NOW.strftime("%Y-%m-%dT%H:%M:%SZ")
        return value

    def test_complete_current_evidence_can_promote_only_the_scanned_source(self):
        value = self.evidence()
        self.assertEqual(policy.validate_promotion(value, IMAGE, SOURCE, EMPTY_POLICY, NOW), value)
        for image, source in ((IMAGE.replace("0" * 64, "1" * 64), SOURCE), (IMAGE, "b" * 40)):
            with self.assertRaises(policy.PolicyError):
                policy.validate_promotion(value, image, source, EMPTY_POLICY, NOW)

    def test_failed_incomplete_or_stale_evidence_cannot_promote(self):
        mutations = [lambda e: e.update(decision="block"), lambda e: e.update(blockedFindings=1),
                     lambda e: e.update(platforms=[]), lambda e: e["platforms"][0].pop("sbom"),
                     lambda e: e.update(scannedAt="2026-09-19T12:00:00Z"),
                     lambda e: e.update(scannedAt="2026-09-22T12:00:00Z"),
                     lambda e: e["scanner"].update(version="0.1.0")]
        for mutation in mutations:
            evidence = self.evidence()
            mutation(evidence)
            with self.assertRaises(policy.PolicyError):
                policy.validate_promotion(evidence, IMAGE, SOURCE, EMPTY_POLICY, NOW)

    def test_changed_or_expired_policy_invalidates_previous_pass(self):
        value = self.evidence()
        with self.assertRaises(policy.PolicyError):
            policy.validate_promotion(value, IMAGE, SOURCE, {"schemaVersion": 1, "exceptions": [exception()]}, NOW)
        _, _, reports = fixture()
        reports["linux/amd64"]["Results"][0]["Vulnerabilities"] = [FINDING]
        exceptions = {"schemaVersion": 1, "exceptions": [exception(expiresOn="2026-09-21")]}
        value = evaluate(reports=reports, exceptions=exceptions)
        value["scannedAt"] = NOW.strftime("%Y-%m-%dT%H:%M:%SZ")
        policy.validate_promotion(value, IMAGE, SOURCE, exceptions, NOW)
        with self.assertRaises(policy.PolicyError):
            policy.validate_promotion(value, IMAGE, SOURCE, exceptions, NOW + timedelta(days=1))

    def test_shell_promotion_rejects_invalid_evidence_before_any_registry_write(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "scripts/security").mkdir(parents=True)
            (root / "scripts/security/image-policy.py").write_text((ROOT / "scripts/security/image-policy.py").read_text())
            (root / "scripts/security/image-exceptions.json").write_text(json.dumps(EMPTY_POLICY))
            (root / "security-evidence").mkdir()
            (root / "security-evidence/evidence.json").write_text(json.dumps({"decision": "pass", "image": IMAGE,
                                                                             "sourceCommit": SOURCE, "blockedFindings": 0}))
            (root / "bin").mkdir()
            fake = root / "bin/docker"
            fake.write_text('#!/usr/bin/env bash\ntouch "$FORBIDDEN_DOCKER_CALL"\nexit 99\n')
            fake.chmod(0o755)
            marker = root / "called"
            result = subprocess.run(["bash", str(ROOT / "scripts/security/promote-image.sh"), IMAGE, SOURCE, "true"],
                                    cwd=root, capture_output=True, text=True,
                                    env={**os.environ, "PATH": str(fake.parent) + os.pathsep + os.environ["PATH"],
                                         "FORBIDDEN_DOCKER_CALL": str(marker)})
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists())
            self.assertNotIn(SECRET, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
