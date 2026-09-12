#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 CANDIDATE_JSON BASELINE_JSON" >&2
  exit 2
fi
candidate_report="$1"
baseline_report="$2"

candidate_total="$(jq '[.Results[]? | (.Vulnerabilities // [])[]] | length' "$candidate_report")"
baseline_total="$(jq '[.Results[]? | (.Vulnerabilities // [])[]] | length' "$baseline_report")"
candidate_os="$(jq '[.Results[]? | select(.Class == "os-pkgs") | (.Vulnerabilities // [])[]] | length' "$candidate_report")"
unexpected="$(
  jq -n \
    --slurpfile candidate "$candidate_report" \
    --slurpfile baseline "$baseline_report" \
    'def findings($report):
       [$report[0].Results[]? | (.Vulnerabilities // [])[] |
        "\(.VulnerabilityID)|\(.PkgName)|\(.InstalledVersion)"] | unique;
     findings($candidate) - findings($baseline)'
)"
unexpected_total="$(jq 'length' <<<"${unexpected}")"

{
  echo '### Backend vulnerability ratchet'
  echo "- Candidate HIGH/CRITICAL findings: ${candidate_total}"
  echo "- Upstream OpenMRS baseline findings: ${baseline_total}"
  echo "- Candidate OS findings with fixes: ${candidate_os}"
  echo "- Findings added beyond upstream: ${unexpected_total}"
} >>"${GITHUB_STEP_SUMMARY}"

if [[ "${candidate_os}" != '0' ]]; then
  echo '::error::The backend still contains fixable HIGH/CRITICAL operating-system vulnerabilities.'
  jq -r '.Results[]? | select(.Class == "os-pkgs") | (.Vulnerabilities // [])[] |
    "\(.Severity) \(.VulnerabilityID) \(.PkgName) \(.InstalledVersion) -> \(.FixedVersion)"' \
    "$candidate_report"
  exit 1
fi

if [[ "${unexpected_total}" != '0' ]]; then
  echo '::error::The SIHSALUS backend adds HIGH/CRITICAL vulnerabilities beyond its pinned OpenMRS base.'
  jq -r '.[]' <<<"${unexpected}"
  exit 1
fi
