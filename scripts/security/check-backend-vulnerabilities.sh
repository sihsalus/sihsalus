#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 2 || "$#" -gt 3 ]]; then
  echo "Usage: $0 CANDIDATE_JSON BASELINE_JSON [POLICY_JSON]" >&2
  exit 2
fi
candidate_report="$1"
baseline_report="$2"
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
policy_file="${3:-$script_directory/image-exceptions.json}"
mode="$(python3 "$script_directory/image-policy.py" mode "$policy_file")"
annotation=error
[[ "$mode" != report-only ]] || annotation=warning

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
  echo "- Vulnerability mode: ${mode}"
  echo "- Candidate HIGH/CRITICAL findings: ${candidate_total}"
  echo "- Upstream OpenMRS baseline findings: ${baseline_total}"
  echo "- Candidate OS findings with fixes: ${candidate_os}"
  echo "- Findings added beyond upstream: ${unexpected_total}"
} >>"${GITHUB_STEP_SUMMARY}"

if [[ "${candidate_os}" != '0' ]]; then
  echo "::${annotation}::The backend contains fixable HIGH/CRITICAL operating-system vulnerabilities."
  jq -r '.Results[]? | select(.Class == "os-pkgs") | (.Vulnerabilities // [])[] |
    "\(.Severity) \(.VulnerabilityID) \(.PkgName) \(.InstalledVersion) -> \(.FixedVersion)"' \
    "$candidate_report"
fi

if [[ "${unexpected_total}" != '0' ]]; then
  echo "::${annotation}::The SIHSALUS backend adds HIGH/CRITICAL vulnerabilities beyond its pinned OpenMRS base."
  jq -r '.[]' <<<"${unexpected}"
fi

if [[ "$mode" == enforce && ( "$candidate_os" != 0 || "$unexpected_total" != 0 ) ]]; then
  exit 1
fi
