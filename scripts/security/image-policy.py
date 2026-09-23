#!/usr/bin/env python3
"""Bind vulnerability decisions to every executable digest in an attested image."""

import argparse
from datetime import date, datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import sys


DIGEST = r"sha256:[0-9a-f]{64}"
REPOSITORY = r"[a-z0-9][a-z0-9.-]*(?::[0-9]+)?(?:/[a-z0-9][a-z0-9._-]*)+"
PLATFORMS = {"linux/amd64", "linux/arm64"}
INDEX_MEDIA = {"application/vnd.oci.image.index.v1+json", "application/vnd.docker.distribution.manifest.list.v2+json"}
MANIFEST_MEDIA = {"application/vnd.oci.image.manifest.v1+json", "application/vnd.docker.distribution.manifest.v2+json"}
EXCEPTION_FIELDS = {"id", "repository", "platform", "vulnerabilityId", "packageName", "installedVersion",
                    "class", "type", "severity", "owner", "issue", "rationale", "createdOn", "expiresOn"}
MATCH_FIELDS = ("repository", "platform", "vulnerabilityId", "packageName", "installedVersion", "class", "type", "severity")


class PolicyError(Exception):
    """Errors describe the failed contract without copying untrusted report data."""


def require(condition, description):
    if not condition:
        raise PolicyError(description)


def matches(value, expression):
    return isinstance(value, str) and re.fullmatch(expression, value) is not None


def fields(value, expected, description):
    require(isinstance(value, dict) and set(value) == expected, description)


def safe_package(value):
    return matches(value, r"[A-Za-z0-9_@+./:~%=-]{1,256}")


def read_json(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "Duplicate JSON key")
            result[key] = value
        return result

    require(path.is_file() and path.stat().st_size <= 64 * 1024 * 1024, "Missing or oversized JSON input")
    return json.loads(path.read_text(), object_pairs_hook=unique)


def image_repository(image):
    require(matches(image, REPOSITORY + "@" + DIGEST), "An exact registry image digest is required")
    return image.split("@", 1)[0]


def executable_platforms(index):
    require(isinstance(index, dict) and index.get("schemaVersion") == 2 and index.get("mediaType") in INDEX_MEDIA,
            "An OCI/Docker index with attached attestations is required")
    descriptors = index.get("manifests")
    require(isinstance(descriptors, list) and 1 <= len(descriptors) <= 20, "Invalid image index descriptors")
    platforms = {}
    attestations = []
    for item in descriptors:
        require(isinstance(item, dict) and item.get("mediaType") in MANIFEST_MEDIA and matches(item.get("digest"), DIGEST),
                "Invalid child manifest descriptor")
        require(type(item.get("size")) is int and item["size"] > 0, "Invalid manifest descriptor size")
        platform = item.get("platform")
        require(isinstance(platform, dict), "Missing manifest platform")
        name = f"{platform.get('os')}/{platform.get('architecture')}"
        annotations = item.get("annotations", {})
        require(isinstance(annotations, dict), "Invalid manifest annotations")
        if name == "unknown/unknown":
            require(annotations.get("vnd.docker.reference.type") == "attestation-manifest",
                    "Unknown-platform entries must be BuildKit attestations")
            subject = annotations.get("vnd.docker.reference.digest")
            require(matches(subject, DIGEST), "Attestation subject digest is missing")
            attestations.append(subject)
            continue
        require(name in PLATFORMS and name not in platforms, "Unsupported or duplicate executable platform")
        require("vnd.docker.reference.type" not in annotations, "Executable image cannot masquerade as an attestation")
        platforms[name] = item["digest"]
    require(platforms and set(attestations) == set(platforms.values()), "Every executable digest must have an attached attestation")
    require(len(set(platforms.values())) == len(platforms), "Executable platforms must have distinct image digests")
    return dict(sorted(platforms.items()))


def parse_day(value):
    require(matches(value, r"[0-9]{4}-[0-9]{2}-[0-9]{2}"), "Exception dates must use YYYY-MM-DD")
    try:
        return date.fromisoformat(value)
    except ValueError:
        raise PolicyError("Invalid exception date") from None


def validate_policy(policy, today=None):
    today = today or datetime.now(timezone.utc).date()
    require(isinstance(policy, dict) and set(policy) in (
        {"schemaVersion", "exceptions"}, {"schemaVersion", "exceptions", "vulnerabilityMode"}),
        "Invalid image policy fields")
    require(vulnerability_mode(policy) in ("enforce", "report-only"), "Invalid vulnerability mode")
    require(type(policy["schemaVersion"]) is int and policy["schemaVersion"] == 1, "Unsupported exception policy version")
    require(isinstance(policy["exceptions"], list) and len(policy["exceptions"]) <= 500, "Invalid exception list")
    identifiers, scopes = set(), set()
    for entry in policy["exceptions"]:
        fields(entry, EXCEPTION_FIELDS, "Each exception needs its exact scope, owner, rationale and expiration")
        require(matches(entry["id"], r"[a-z0-9][a-z0-9-]{0,63}") and entry["id"] not in identifiers,
                "Invalid or duplicate exception identifier")
        require(matches(entry["repository"], REPOSITORY) and entry["platform"] in PLATFORMS, "Invalid exception image scope")
        require(matches(entry["vulnerabilityId"], r"[A-Za-z0-9][A-Za-z0-9._-]{2,127}"), "Invalid vulnerability identifier")
        require(safe_package(entry["packageName"]) and safe_package(entry["installedVersion"]), "Invalid exception package scope")
        require(entry["class"] in ("os-pkgs", "lang-pkgs") and entry["severity"] in ("HIGH", "CRITICAL"),
                "Invalid exception class or severity")
        require(matches(entry["type"], r"[a-z][a-z0-9-]{0,63}"), "An exact package ecosystem is required")
        require(matches(entry["owner"], r"@[A-Za-z0-9][A-Za-z0-9-]{0,38}(?:/[A-Za-z0-9][A-Za-z0-9_-]{0,99})?"),
                "An accountable GitHub owner or team is required")
        require(matches(entry["issue"], r"https://github\.com/sihsalus/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*"),
                "An SIHSalus tracking issue is required")
        rationale = entry["rationale"]
        require(isinstance(rationale, str) and 20 <= len(rationale) <= 2000 and all(ord(character) >= 32 for character in rationale),
                "A concrete, single-line exception rationale is required")
        created, expires = parse_day(entry["createdOn"]), parse_day(entry["expiresOn"])
        require(created <= today <= expires and 0 < (expires - created).days <= 30,
                "Exceptions must be current and expire within 30 days of creation")
        scope = tuple(entry[key] for key in MATCH_FIELDS)
        require(scope not in scopes, "Duplicate exception scope")
        identifiers.add(entry["id"])
        scopes.add(scope)
    return policy


def vulnerability_mode(policy):
    # Historical policies without this field retain their blocking behavior.
    return policy.get("vulnerabilityMode", "enforce")


def platform_sbom(document, platform, platforms):
    require(isinstance(document, dict), "Missing BuildKit SBOM data")
    # Buildx exposes .SBOM.SPDX for one executable platform and a map for
    # multiple platforms. Support both official shapes without ignoring one.
    selected = document if "SPDX" in document and len(platforms) == 1 else document.get(platform)
    require(isinstance(selected, dict) and isinstance(selected.get("SPDX"), dict), "Missing platform SPDX attestation")
    spdx = selected["SPDX"]
    require(spdx.get("spdxVersion") in ("SPDX-2.2", "SPDX-2.3") and spdx.get("SPDXID") == "SPDXRef-DOCUMENT",
            "Invalid SPDX document identity")
    require(isinstance(spdx.get("documentNamespace"), str) and spdx["documentNamespace"], "Missing SPDX document namespace")
    packages = spdx.get("packages")
    require(isinstance(packages, list) and packages and all(isinstance(package, dict) for package in packages),
            "Published service images must contain a nonempty SPDX package inventory")
    digest = hashlib.sha256(json.dumps(spdx, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return {"format": spdx["spdxVersion"], "sha256": digest, "packageCount": len(packages)}


def scan_findings(report, subject, platform, source):
    require(isinstance(report, dict) and report.get("SchemaVersion") == 2 and report.get("ArtifactType") == "container_image",
            "Invalid Trivy container report")
    require(report.get("ArtifactName") == subject, "Scan subject differs from the requested child digest")
    metadata = report.get("Metadata")
    require(isinstance(metadata, dict) and matches(metadata.get("ImageID"), DIGEST), "Missing scanned image identity")
    configuration = metadata.get("ImageConfig")
    require(isinstance(configuration, dict) and f"{configuration.get('os')}/{configuration.get('architecture')}" == platform,
            "Scanned image architecture differs from the index platform")
    image_config = configuration.get("config", {})
    require(isinstance(image_config, dict) and isinstance(image_config.get("Labels"), dict)
            and image_config["Labels"].get("org.opencontainers.image.revision") == source,
            "Packaged image revision differs from the requested source commit")
    results = report.get("Results")
    require(isinstance(results, list) and any(isinstance(result, dict) and result.get("Class") == "os-pkgs" for result in results),
            "Published service images require an operating-system package scan")
    findings = {}
    for result in results:
        require(isinstance(result, dict), "Invalid vulnerability result")
        require(not result.get("Secrets") and not result.get("Misconfigurations"), "Only vulnerability scan data is accepted")
        vulnerabilities = result.get("Vulnerabilities") or []
        require(isinstance(vulnerabilities, list), "Invalid vulnerability list")
        for vulnerability in vulnerabilities:
            require(isinstance(vulnerability, dict), "Invalid vulnerability finding")
            severity = vulnerability.get("Severity")
            require(severity in ("UNKNOWN", "LOW", "MEDIUM", "HIGH", "CRITICAL"), "Unknown severity classification")
            if severity not in ("HIGH", "CRITICAL"):
                continue
            identifier = vulnerability.get("VulnerabilityID")
            package, installed = vulnerability.get("PkgName"), vulnerability.get("InstalledVersion")
            fixed = vulnerability.get("FixedVersion", "")
            require(matches(identifier, r"[A-Za-z0-9][A-Za-z0-9._-]{2,127}") and safe_package(package) and safe_package(installed),
                    "Invalid finding identity")
            # FixedVersion can be a comma/space-separated set of fixed ranges.
            require(isinstance(fixed, str) and len(fixed) <= 1024 and matches(fixed, r"[A-Za-z0-9_@+./:~%,= <>!-]*"),
                    "Invalid fixed-version metadata")
            require(result.get("Class") in ("os-pkgs", "lang-pkgs"), "Unsupported vulnerability class")
            require(matches(result.get("Type"), r"[a-z][a-z0-9-]{0,63}"), "Missing package ecosystem")
            finding = {"vulnerabilityId": identifier, "packageName": package, "installedVersion": installed,
                       "fixedVersion": fixed, "severity": severity, "class": result["Class"], "type": result["Type"]}
            key = tuple(finding[field] for field in ("vulnerabilityId", "packageName", "installedVersion", "class", "type", "severity"))
            findings[key] = finding
    # Never copy ImageConfig, Env, target paths, descriptions, source snippets,
    # secret matches or arbitrary scanner fields to retained evidence.
    return [findings[key] for key in sorted(findings)]


def evaluate(image, source, scanner, index, sbom, reports, policy, today=None):
    repository = image_repository(image)
    require(matches(source, r"[0-9a-f]{40}"), "A complete source commit is required")
    require(matches(scanner, r"[0-9]+\.[0-9]+\.[0-9]+"), "An exact scanner version is required")
    platforms = executable_platforms(index)
    validate_policy(policy, today)
    unaccepted = "warn" if vulnerability_mode(policy) == "report-only" else "block"
    require(set(reports) == set(platforms), "Every executable platform must have exactly one scan")
    exceptions = {tuple(entry[field] for field in MATCH_FIELDS): entry for entry in policy["exceptions"]}
    output = []
    blocked = 0
    for platform, child in platforms.items():
        subject = f"{repository}@{child}"
        findings = scan_findings(reports[platform], subject, platform, source)
        for finding in findings:
            scope = {"repository": repository, "platform": platform, **finding}
            exception = exceptions.get(tuple(scope[field] for field in MATCH_FIELDS))
            finding["decision"] = "exception" if exception else unaccepted
            if exception:
                finding["exception"] = {key: exception[key] for key in ("id", "owner", "expiresOn", "issue")}
            else:
                blocked += 1
        output.append({"platform": platform, "image": subject, "sbom": platform_sbom(sbom, platform, platforms), "findings": findings})
    return {"schemaVersion": 1, "image": image, "sourceCommit": source, "scanner": {"name": "Trivy", "version": scanner},
            "scannedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "policySha256": hashlib.sha256(json.dumps(policy, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
            "platforms": output, "blockedFindings": blocked, "decision": unaccepted if blocked else "pass"}


def validate_promotion(evidence, image, source, policy, now=None):
    now = now or datetime.now(timezone.utc)
    validate_policy(policy, now.date())
    image_repository(image)
    require(matches(source, r"[0-9a-f]{40}"), "Invalid source commit")
    fields(evidence, {"schemaVersion", "image", "sourceCommit", "scanner", "scannedAt", "policySha256", "platforms", "blockedFindings", "decision"},
           "Complete sanitized security evidence is required")
    require(evidence["schemaVersion"] == 1 and evidence["image"] == image and evidence["sourceCommit"] == source,
            "Security evidence belongs to another image or commit")
    require(evidence["scanner"] == {"name": "Trivy", "version": "0.74.0"}, "Evidence uses an unreviewed scanner version")
    report_only = vulnerability_mode(policy) == "report-only"
    require(type(evidence["blockedFindings"]) is int and evidence["blockedFindings"] >= 0,
            "Invalid finding count")
    expected_decision = "warn" if report_only and evidence["blockedFindings"] else "pass"
    require(evidence["decision"] == expected_decision and (report_only or evidence["blockedFindings"] == 0),
            "Image security evidence does not permit promotion")
    expected = hashlib.sha256(json.dumps(policy, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    require(evidence["policySha256"] == expected, "Exception policy changed after the scan")
    require(matches(evidence["scannedAt"], r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"), "Missing scan timestamp")
    scanned = datetime.strptime(evidence["scannedAt"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    require(-300 <= (now - scanned).total_seconds() <= 24 * 60 * 60, "Evidence is stale or dated in the future")
    platforms = evidence["platforms"]
    require(isinstance(platforms, list) and platforms, "Platform evidence is missing")
    seen = set()
    warnings = 0
    for item in platforms:
        fields(item, {"platform", "image", "sbom", "findings"}, "Invalid platform evidence")
        require(item["platform"] in PLATFORMS and item["platform"] not in seen, "Invalid evidence platform coverage")
        seen.add(item["platform"])
        require(image_repository(item["image"]) == image_repository(image), "Evidence child repository differs")
        fields(item["sbom"], {"format", "sha256", "packageCount"}, "Missing SPDX evidence")
        require(item["sbom"]["format"] in ("SPDX-2.2", "SPDX-2.3") and matches(item["sbom"]["sha256"], r"[0-9a-f]{64}")
                and type(item["sbom"]["packageCount"]) is int and item["sbom"]["packageCount"] > 0, "Invalid SPDX evidence")
        require(isinstance(item["findings"], list), "Invalid evidence findings")
        for finding in item["findings"]:
            if report_only and isinstance(finding, dict) and finding.get("decision") == "warn":
                fields(finding, {"vulnerabilityId", "packageName", "installedVersion", "fixedVersion", "severity",
                                 "class", "type", "decision"}, "Invalid warning evidence")
                require(matches(finding["vulnerabilityId"], r"[A-Za-z0-9][A-Za-z0-9._-]{2,127}")
                        and safe_package(finding["packageName"]) and safe_package(finding["installedVersion"])
                        and finding["severity"] in ("HIGH", "CRITICAL")
                        and finding["class"] in ("os-pkgs", "lang-pkgs")
                        and matches(finding["type"], r"[a-z][a-z0-9-]{0,63}")
                        and matches(finding["fixedVersion"], r"[A-Za-z0-9_@+./:~%,= <>!-]{0,1024}"),
                        "Invalid warning finding")
                warnings += 1
                continue
            require(isinstance(finding, dict) and finding.get("decision") == "exception", "Unaccepted finding in promotion evidence")
            scope = {"repository": image_repository(image), "platform": item["platform"], **finding}
            candidates = [entry for entry in policy["exceptions"] if all(entry[key] == scope.get(key) for key in MATCH_FIELDS)]
            require(len(candidates) == 1 and finding.get("exception") == {
                key: candidates[0][key] for key in ("id", "owner", "expiresOn", "issue")}, "Finding lacks its current reviewed exception")
    require(warnings == evidence["blockedFindings"], "Finding count differs from retained evidence")
    return evidence


def write_evidence(path, value):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as output:
        json.dump(value, output, indent=2, sort_keys=True)
        output.write("\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    policy_command = commands.add_parser("check-policy")
    policy_command.add_argument("policy", type=Path)
    mode_command = commands.add_parser("mode")
    mode_command.add_argument("policy", type=Path)
    platforms_command = commands.add_parser("platforms")
    platforms_command.add_argument("image")
    platforms_command.add_argument("index", type=Path)
    check = commands.add_parser("evaluate")
    for name in ("image", "source", "scanner"):
        check.add_argument("--" + name, required=True)
    for name in ("index", "sbom", "reports", "policy", "output"):
        check.add_argument("--" + name, required=True, type=Path)
    args = parser.parse_args()
    if args.command == "mode":
        print(vulnerability_mode(validate_policy(read_json(args.policy))))
        return 0
    if args.command == "check-policy":
        policy = validate_policy(read_json(args.policy))
        print(f"Validated {len(policy['exceptions'])} current, explicitly scoped exceptions")
        return 0
    if args.command == "platforms":
        image_repository(args.image)
        for platform, digest in executable_platforms(read_json(args.index)).items():
            print(f"{platform}\t{digest}")
        return 0
    index = read_json(args.index)
    reports = {platform: read_json(args.reports / (platform.replace("/", "-") + ".json"))
               for platform in executable_platforms(index)}
    evidence = evaluate(args.image, args.source, args.scanner, index, read_json(args.sbom), reports, read_json(args.policy))
    write_evidence(args.output, evidence)
    print(f"Image policy: {evidence['decision']}; {len(evidence['platforms'])} platforms; {evidence['blockedFindings']} unexcepted HIGH/CRITICAL findings")
    if evidence["decision"] == "warn":
        print(f"::warning::Image has {evidence['blockedFindings']} unexcepted HIGH/CRITICAL findings; vulnerability mode is report-only")
    return 1 if evidence["decision"] == "block" else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except PolicyError as error:
        print(f"[image-policy] {error}", file=sys.stderr)
        sys.exit(2)
    except (OSError, ValueError, TypeError, KeyError):
        print("[image-policy] Invalid or unavailable input; raw scanner/configuration data is not displayed", file=sys.stderr)
        sys.exit(2)
