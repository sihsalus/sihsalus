#!/usr/bin/env python3
"""Synchronize the dedicated host's configuration through a restricted SSH key."""
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
# Public environment variable names only; credential values arrive separately.
CREDENTIAL_SETTING_NAMES = tuple("TERMINOLOGY_" + key for key in (
    "DB_PASSWORD", "SECRET_KEY", "ADMIN_PASSWORD", "ADMIN_TOKEN",
    "STORAGE_ACCESS_KEY", "STORAGE_SECRET_KEY", "EMAIL_HOST_PASSWORD",
))
VARIABLE_KEYS = tuple("TERMINOLOGY_" + key for key in (
    "HOST", "API_HOST", "MACHINE_ID", "BACKUP_KEEP", "EMAIL_BACKEND",
    "EMAIL_HOST", "EMAIL_PORT", "EMAIL_HOST_USER", "DEFAULT_FROM_EMAIL",
    "COMMUNITY_EMAIL", "REPORTS_EMAIL", "ADMIN_EMAIL",
))
CONFIG_KEYS = CREDENTIAL_SETTING_NAMES + VARIABLE_KEYS
DEFAULTS = {"TERMINOLOGY_BACKUP_KEEP": "14"}


class ConfigurationError(Exception):
    """A diagnostic intentionally limited to non-secret operational metadata."""


def require(condition, message):
    """Fail with an operator-readable message that contains no setting values."""
    if not condition:
        raise ConfigurationError(message)


def read_configuration(path):
    """Use the deployment's existing dotenv reader, without sourcing secrets."""
    result = subprocess.check_output([
        "bash", "-c",
        'source "$1"; shift; config_file="$1"; shift; '
        'for key; do read_env_value "$key" "$config_file"; printf "\\0"; done',
        "_", str(ROOT / "scripts/deploy/env.sh"), str(path), *CONFIG_KEYS,
    ], text=True)
    values = dict(zip(CONFIG_KEYS, (value.rstrip("\n") for value in result.split("\0")[:-1])))
    return {name: value or DEFAULTS.get(name, "") for name, value in values.items()}


def send():
    """Send secrets over stdin; never interpolate them into a shell command."""
    target = os.environ["TERMINOLOGY_SSH_TARGET"]
    require(re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_-]*@[a-zA-Z0-9.-]+", target), "Invalid SSH target")
    payload = {
        "commit": os.environ["GITHUB_SHA"],
        "mode": os.environ["CONFIGURATION_MODE"],
        "settings": {key: os.environ.get(key, "") for key in CONFIG_KEYS},
    }
    with tempfile.TemporaryDirectory(prefix="terminology-ssh-") as directory:
        directory = Path(directory)
        key = directory / "key"
        known_hosts = directory / "known_hosts"
        key.write_text(os.environ["TERMINOLOGY_SSH_PRIVATE_KEY"].rstrip() + "\n")
        known_hosts.write_text(os.environ["TERMINOLOGY_SSH_KNOWN_HOSTS"].rstrip() + "\n")
        key.chmod(0o600)
        known_hosts.chmod(0o600)
        subprocess.run([
            "ssh", "-i", str(key), "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={known_hosts}",
            "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=6", target, "terminology-config",
        ], input=json.dumps(payload), text=True, check=True, timeout=1800)


def receive():
    """Apply only managed settings to the already installed, reviewed release."""
    require(os.environ.get("SSH_ORIGINAL_COMMAND") == "terminology-config", "Unsupported SSH command")
    raw = sys.stdin.buffer.read(65537)
    require(len(raw) <= 65536, "Configuration payload is too large")
    payload = json.loads(raw)
    require(set(payload) == {"commit", "mode", "settings"}, "Unexpected payload fields")
    require(payload["mode"] in ("check", "apply"), "Unsupported configuration mode")
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    require(payload["commit"] == commit, "Install the requested operations commit on the host first")
    require(not subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip(),
            "The operations checkout must be clean")
    settings = payload["settings"]
    require(isinstance(settings, dict) and set(settings) == set(CONFIG_KEYS), "Unexpected configuration keys")
    for name, value in settings.items():
        require(isinstance(value, str) and not any(c in value for c in "\n\r\0'"),
                "Unsupported scalar format: " + name)
        require(bool(value) or name == "TERMINOLOGY_ADMIN_EMAIL", "Missing configuration: " + name)
    require(settings["TERMINOLOGY_BACKUP_KEEP"].isdigit()
            and int(settings["TERMINOLOGY_BACKUP_KEEP"]) >= 2, "Invalid backup retention")
    require(settings["TERMINOLOGY_EMAIL_PORT"].isdigit()
            and 0 < int(settings["TERMINOLOGY_EMAIL_PORT"]) <= 65535, "Invalid SMTP port")
    require(settings["TERMINOLOGY_EMAIL_BACKEND"] in (
        "django.core.mail.backends.dummy.EmailBackend", "django.core.mail.backends.smtp.EmailBackend",
    ), "Unsupported email backend")
    state_root = ROOT / ".env.terminology-state"
    require(state_root.is_dir(), "An initialized deployment is required")
    with (state_root / "github-config.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        current_path = ROOT / ".env.terminology"
        active_path = state_root / "active.env"
        require(not current_path.is_symlink() and current_path.stat().st_mode & 0o777 == 0o600,
                "Private configuration must be a regular file with mode 600")
        require(current_path.read_bytes() == active_path.read_bytes(), "Resolve the pending deployment first")
        current = read_configuration(current_path)
        require(Path("/etc/machine-id").read_text().strip() == current["TERMINOLOGY_MACHINE_ID"],
                "Unexpected host identity")
        # Changing these values alone cannot rotate the persisted service credentials.
        immutable = set(CREDENTIAL_SETTING_NAMES) - {"TERMINOLOGY_EMAIL_HOST_PASSWORD"}
        immutable.update({"TERMINOLOGY_HOST", "TERMINOLOGY_API_HOST", "TERMINOLOGY_MACHINE_ID"})
        for name in immutable:
            require(settings[name] == current[name], "Requires a coordinated migration or rotation: " + name)
        changed = [name for name in CONFIG_KEYS if settings[name] != current[name]]
        if payload["mode"] == "check" or not changed:
            print(json.dumps({"status": "checked" if changed else "unchanged", "changed_keys": changed,
                              "settings_matched": len(CONFIG_KEYS) - len(changed), "commit": commit}))
            return
        state = state_root / ("github-config-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"))
        state.mkdir(mode=0o700)
        shutil.copy2(current_path, state / "previous.env")
        output = []
        remaining = dict(settings)
        for line in current_path.read_text().splitlines():
            match = re.match(r"\s*(?:export\s+)?([A-Z][A-Z0-9_]*)\s*=", line)
            name = match[1] if match else None
            if name in settings:
                if name in remaining:
                    output.append(name + "='" + remaining.pop(name) + "'")
            else:
                output.append(line)
        output.extend(name + "='" + value + "'" for name, value in remaining.items())
        candidate = state / "target.env"
        candidate.write_text("\n".join(output) + "\n")
        with (state / "deploy.log").open("w") as log:
            subprocess.run(["docker", "compose", "--env-file", str(candidate), "-f",
                            "docker-compose.terminology.yml", "config", "--quiet"],
                           cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
            temporary = ROOT / ".env.github-configuration"
            shutil.copy2(candidate, temporary)
            temporary.replace(current_path)
            result = subprocess.run([
                "bash", "scripts/deploy/deploy-terminology.sh", str(current_path), "update",
                str(ROOT.parent / "terminology-backups"),
            ], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        (state / "exit").write_text(str(result.returncode) + "\n")
        require(result.returncode == 0, "Deployment failed; inspect the private recovery journal: " + state.name)
        print(json.dumps({"status": "applied", "changed_keys": changed, "commit": commit,
                          "journal": state.name}))


if __name__ == "__main__":
    os.umask(0o077)
    try:
        require(len(sys.argv) == 2 and sys.argv[1] in ("send", "receive"), "Choose send or receive")
        send() if sys.argv[1] == "send" else receive()
    except ConfigurationError as error:
        print("Configuration stopped: " + str(error), file=sys.stderr)
        sys.exit(1)
    except Exception as error:
        # Exceptions from SSH/JSON/settings must not echo credentials or payloads.
        print("Configuration stopped: " + type(error).__name__, file=sys.stderr)
        sys.exit(1)
