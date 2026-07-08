# Security Policy

## Supported scope

Security reports are accepted for the current `main` branch and the currently deployed SIHSalus environment.

In scope:
- Docker Compose configuration, profiles and deployment scripts.
- Gateway, HTTPS, CSP and reverse proxy configuration.
- OpenMRS backend distribution configuration.
- Keycloak/OAuth2 integration.
- CI workflows and supply-chain configuration.
- Handling of secrets, credentials, tokens and sensitive operational data.

Out of scope:
- Social engineering, phishing or physical attacks.
- Denial-of-service testing without prior authorization.
- Vulnerabilities in upstream projects unless SIHSalus configuration makes them exploitable.
- Public disclosure before maintainers have had time to triage and mitigate.

## Reporting a vulnerability

Use GitHub private vulnerability reporting or Security Advisories when available.

If private reporting is not available, contact a maintainer directly and avoid public issues for sensitive reports.

Do not include real patient data, production credentials, tokens, private keys or screenshots containing personal data.

## Response targets

These targets are operational goals, not legal guarantees.

| Severity | Acknowledge | Triage target | Mitigation target |
| --- | ---: | ---: | ---: |
| Critical | 1 business day | 3 calendar days | 7 calendar days |
| High | 2 business days | 7 calendar days | 14 calendar days |
| Medium | 3 business days | 14 calendar days | 30 calendar days |
| Low | 5 business days | 30 calendar days | Best effort |

## Coordinated disclosure

Please give maintainers a reasonable opportunity to investigate and mitigate before public disclosure.

Maintainers will credit reporters when appropriate and requested.
