#!/usr/bin/env python3
"""Exercise only repository-owned synthetic IPS fixtures with the HL7 validator.

This is a development check, not a backend service, clinical exporter, or claim
of accreditation. The validator may contact public terminology/package servers;
there is deliberately no argument for supplying patient records.
"""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import urllib.request

from document_identity import DocumentIdentityError, assert_document_patient_identity

HERE = Path(__file__).resolve().parent
VALIDATOR_VERSION = "7.0.2"
VALIDATOR_URL = (
    "https://github.com/hapifhir/org.hl7.fhir.core/releases/download/"
    f"{VALIDATOR_VERSION}/validator_cli.jar"
)
VALIDATOR_SHA256 = "e3e50f06b806437821b7aef8189a1b790415cb96c5036e0812ed62981452b377"
PACKAGE_URL = "https://dyaku.minsa.gob.pe/guides/package.tgz"
PACKAGE_SHA256 = "f2928f5fda2549721c62ba7bcabd32288a93e2bc87c1bef293bf87a35938ecc7"
PROFILE = "https://www.gob.pe/minsa/RENHICE/fhir/StructureDefinition/BundlePe"
TERMINOLOGY_SERVER = "https://tx.fhir.org/r4"
CASES = (
    ("positive-corepe-document", True),
    ("negative-unresolved-reference", False),
    ("negative-extra-immunization", False),
    ("semantic-cross-patient", True),
)
EXPECTED_ERRORS = {
    "negative-unresolved-reference": {("Bundle_BUNDLE_Entry_NotFound", "Bundle.entry[1].resource.subject")},
    "negative-extra-immunization": {("Validation_VAL_Profile_NotSlice", "Bundle.entry[7]")},
}
EXPECTED_IDENTITY = {
    "positive-corepe-document": None,
    "negative-unresolved-reference": "identity_reference_unresolved",
    "negative-extra-immunization": None,
    "semantic-cross-patient": "identity_patient_mismatch",
}
COMMON_WARNINGS = (
    ("Terminology_TX_NoValid_2_CC", ("Bundle.entry[1].resource.identifier[0].type",)),
    ("Terminology_TX_NoValid_2_CC", ("Bundle.entry[2].resource.identifier[0].type",)),
    ("Terminology_TX_ValueSet_NotFound", ("Bundle.entry[4].resource.code.coding[0].code",)),
)


def sha256(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def verified_download(url: str, destination: Path, expected: str) -> Path:
    """A changed official draft must be reviewed; never silently update its pin."""
    if destination.exists():
        if sha256(destination) != expected:
            raise ValueError(f"Checksum mismatch: {destination.name}")
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".part")
    try:
        with urllib.request.urlopen(url, timeout=60) as response, temporary.open("wb") as target:
            if not response.url.startswith("https://"):
                raise ValueError("Download redirected to a non-HTTPS URL")
            shutil.copyfileobj(response, target)
        if sha256(temporary) != expected:
            raise ValueError(f"Checksum mismatch: {destination.name}; review the upstream artifact")
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)
    return destination


def issues(outcome: dict) -> list[dict]:
    if not isinstance(outcome, dict):
        raise ValueError("Validator produced a malformed outcome")
    if outcome.get("resourceType") == "OperationOutcome":
        result = outcome.get("issue")
        if not isinstance(result, list) or not result or any(
            not isinstance(issue, dict) or issue.get("severity") not in {"fatal", "error", "warning", "information"}
            for issue in result
        ):
            raise ValueError("Validator produced no issue collection")
        return result
    if outcome.get("resourceType") == "Bundle":
        entries = outcome.get("entry")
        if not isinstance(entries, list) or not entries:
            raise ValueError("Validator produced an empty result bundle")
        return [issue for entry in entries for issue in issues(entry["resource"])]
    raise ValueError("Validator did not produce an OperationOutcome")


def message_id(issue: dict) -> str | None:
    return next((extension.get("valueCode") for extension in issue.get("extension", [])
                 if extension.get("url") == "http://hl7.org/fhir/StructureDefinition/operationoutcome-message-id"), None)


def expected_rejection(name: str, errors: list[dict]) -> bool:
    """A crash or unrelated validation failure is not a successful negative test."""
    expected = EXPECTED_ERRORS.get(name, set())
    observed = {(message_id(issue), expression) for issue in errors
                for expression in issue.get("expression", [])}
    return bool(errors) and bool(expected) and observed == expected and all(
        issue.get("severity") == "error" and issue.get("expression") for issue in errors
    )


def reviewed_warnings(name: str, found: list[dict]) -> bool:
    # These are defects/limitations of the unchanged official draft, not
    # suppressed diagnostics. Any additional or changed warning blocks this
    # development baseline until its cause and scope are reviewed.
    expected = list(COMMON_WARNINGS)
    if name == "negative-unresolved-reference":
        expected.append(("Bundle_BUNDLE_Not_Local", ("Bundle.entry[0].resource.subject",)))
    if name == "semantic-cross-patient":
        expected.append(("Terminology_TX_NoValid_2_CC", ("Bundle.entry[4].resource.contained[0].identifier[0].type",)))
    actual = [(message_id(issue), tuple(re.sub(r"/\*.*?\*/", "", value) for value in issue.get("expression", [])))
              for issue in found if issue.get("severity") == "warning"]
    return Counter(actual) == Counter(expected)


def prepare_output(output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    # Only remove this suite's known generated outputs. A failed first case
    # must not publish old later-case evidence under the current CI revision.
    for name, _ in CASES:
        for suffix in (".outcome.json", ".log"):
            (output / f"{name}{suffix}").unlink(missing_ok=True)
    (output / "summary.json").unlink(missing_ok=True)


def run_identity_case(name: str) -> dict:
    fixture = HERE / "fixtures" / f"{name}.json"
    error_code = None
    try:
        assert_document_patient_identity(json.loads(fixture.read_text()))
    except DocumentIdentityError as error:
        error_code = str(error)
    return {"fixture": fixture.name, "expected_error": EXPECTED_IDENTITY[name],
            "actual_error": error_code, "passed": error_code == EXPECTED_IDENTITY[name]}


def run_case(java: str, jar: Path, package: Path, output: Path, name: str, valid: bool) -> dict:
    fixture = HERE / "fixtures" / f"{name}.json"
    outcome_path = output / f"{name}.outcome.json"
    # A previous result is not evidence for this invocation.
    outcome_path.unlink(missing_ok=True)
    command = [
        java, "-Xmx2g", "-jar", str(jar), str(fixture),
        "-version", "4.0.1", "-ig", str(package), "-profile", PROFILE,
        "-tx", TERMINOLOGY_SERVER, "-output", str(outcome_path),
    ]
    with (output / f"{name}.log").open("w") as log:
        completed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=900, check=False)
    if not outcome_path.exists():
        raise ValueError(f"{name}: validator failed without an outcome (exit {completed.returncode})")
    found = issues(json.loads(outcome_path.read_text()))
    errors = [issue for issue in found if issue.get("severity") in {"error", "fatal"}]
    warnings = sum(issue.get("severity") == "warning" for issue in found)
    # The positive fixture must succeed before negative cases can demonstrate a
    # regression guard. Unknown exit codes are infrastructure failures.
    profile_passed = completed.returncode in {0, 1} and (
        (not errors and completed.returncode == 0) if valid else expected_rejection(name, errors)
    )
    warnings_reviewed = reviewed_warnings(name, found)
    return {
        "fixture": fixture.name,
        "fixture_sha256": sha256(fixture),
        "expected_profile_valid": valid,
        "validator_exit": completed.returncode,
        "errors": len(errors),
        "warnings": warnings,
        "warning_ids": sorted({message_id(issue) or "unknown" for issue in found if issue.get("severity") == "warning"}),
        "profile_passed": profile_passed,
        "warnings_reviewed": warnings_reviewed,
        "passed": profile_passed and warnings_reviewed,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, required=True, help="Development artifact cache, outside the source tree")
    parser.add_argument("--output", type=Path, default=HERE.parents[1] / "target" / "interop-conformance")
    args = parser.parse_args()
    output = args.output.resolve()
    prepare_output(output)
    report = {
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "scope": "Synthetic CorePE draft fixtures only; no runtime or accreditation acceptance",
        "validator_version": VALIDATOR_VERSION,
        "validator_sha256": VALIDATOR_SHA256,
        "package_sha256": PACKAGE_SHA256,
        "profile": PROFILE,
        "terminology_server": TERMINOLOGY_SERVER,
        "cases": [],
        "identity_cases": [],
        "passed": False,
    }
    try:
        java = shutil.which("java")
        if not java:
            raise ValueError("Java 21 or newer is required for the development validator")
        jar = verified_download(VALIDATOR_URL, args.cache / f"validator_cli-{VALIDATOR_VERSION}.jar", VALIDATOR_SHA256)
        package = verified_download(PACKAGE_URL, args.cache / "package.tgz", PACKAGE_SHA256)
        for name, valid in CASES:
            result = run_case(java, jar, package, output, name, valid)
            report["cases"].append(result)
            print(json.dumps(result), flush=True)
            if valid and not result["passed"]:
                raise ValueError("Positive fixture did not validate; negative results cannot establish conformance")
            report["identity_cases"].append(run_identity_case(name))
        report["passed"] = all(case["passed"] for case in report["cases"] + report["identity_cases"])
    except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        report["failure"] = str(error)
        print(f"Conformance check blocked: {error}", file=sys.stderr)
    (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
