"""Exercise the actual ephemeral Redis service with synthetic session data only."""

import json
from pathlib import Path
import subprocess
import time
import uuid


ROOT = Path(__file__).resolve().parents[2]
IMAGE = "redis:8.2.9-alpine3.22"
PASSWORD = "0123456789abcdef0123456789abcdef0123456789abcdef"
CONTAINERS = []


def docker(*arguments, check=True, timeout=30):
    return subprocess.run(
        ["docker", *arguments], check=check, capture_output=True, text=True, timeout=timeout
    )


def create_container(password=PASSWORD):
    # Creating before starting makes cleanup ownership recoverable even if the
    # entrypoint rejects its configuration. The test has no network interface.
    container = docker(
        "create", "--name", "sihsalus-imaging-redis-test-" + uuid.uuid4().hex,
        "--network", "none", "--user", "redis", "--read-only", "--memory", "192m",
        "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true",
        "--tmpfs", "/data:rw,noexec,nosuid,size=8m,mode=1777",
        "-e", "IMAGING_REDIS_PASSWORD=" + password,
        "-v", str(ROOT / "imaging/redis-entrypoint.sh") + ":/opt/sihsalus/redis-entrypoint.sh:ro",
        "-v", str(ROOT / "imaging/redis-healthcheck.sh") + ":/opt/sihsalus/redis-healthcheck.sh:ro",
        "--entrypoint", "/bin/sh", IMAGE, "/opt/sihsalus/redis-entrypoint.sh",
        timeout=180,
    ).stdout.strip()
    CONTAINERS.append(container)
    docker("start", container)
    return container


def redis(container, *arguments, password=PASSWORD, check=True):
    return docker(
        "exec", "-e", "REDISCLI_AUTH=" + password, container,
        "redis-cli", "--no-auth-warning", "-2", "--json", *arguments,
        check=check,
    )


def response(container, *arguments):
    return json.loads(redis(container, *arguments).stdout)


def wait_ready(container):
    for _ in range(30):
        result = docker("exec", container, "/bin/sh", "/opt/sihsalus/redis-healthcheck.sh", check=False)
        if result.returncode == 0:
            return
        time.sleep(1)
    raise AssertionError("Synthetic Redis did not become healthy")


def exercise():
    container = create_container()
    wait_ready(container)
    assert response(container, "PING") == "PONG"
    unauthenticated = docker("exec", container, "redis-cli", "PING", check=False)
    assert "NOAUTH" in unauthenticated.stdout
    wrong_password = redis(container, "PING", password="a" * 48, check=False)
    assert "WRONGPASS" in wrong_password.stderr + wrong_password.stdout

    for option, expected in (
        ("save", ""), ("appendonly", "no"), ("maxmemory", "134217728"),
        ("maxmemory-policy", "noeviction"), ("protected-mode", "yes"),
    ):
        assert response(container, "CONFIG", "GET", option) == [option, expected], option

    # Large provider claims stay server-side; Redis TTL removes expired state.
    assert response(container, "SET", "synthetic-large-session", "s" * 20000, "EX", "28800") == "OK"
    assert response(container, "STRLEN", "synthetic-large-session") == 20000
    assert 0 < response(container, "TTL", "synthetic-large-session") <= 28800
    assert response(container, "SET", "synthetic-expiring-session", "synthetic", "EX", "1") == "OK"
    for _ in range(10):
        if response(container, "EXISTS", "synthetic-expiring-session") == 0:
            break
        time.sleep(0.2)
    assert response(container, "EXISTS", "synthetic-expiring-session") == 0

    # Exhaustion must reject writes rather than silently evict an active login.
    assert response(container, "CONFIG", "SET", "maxmemory", "1") == "OK"
    rejected = redis(container, "SET", "synthetic-rejected-session", "synthetic", check=False)
    assert "OOM" in rejected.stdout + rejected.stderr
    assert response(container, "EXISTS", "synthetic-large-session") == 1
    assert response(container, "CONFIG", "SET", "maxmemory", "128mb") == "OK"

    # argv contains only a private config path, never the credential.
    cmdline = docker("exec", container, "/bin/sh", "-c", "tr '\\000' ' ' </proc/1/cmdline").stdout
    assert PASSWORD not in cmdline
    docker("restart", container)
    wait_ready(container)
    assert response(container, "DBSIZE") == 0

    # Missing, short and syntactically unsafe input fails before Redis starts;
    # the credential itself must not be reflected into parser error logs.
    for invalid in ("", "a" * 47, "g" * 48, 'synthetic-secret"\nport 9999'):
        invalid_container = create_container(invalid)
        status = docker("wait", invalid_container).stdout.strip()
        assert status != "0"
        logs = docker("logs", invalid_container)
        output = logs.stdout + logs.stderr
        assert "48 lowercase hexadecimal characters" in output
        if invalid:
            assert invalid not in output


if __name__ == "__main__":
    try:
        exercise()
        print("[OK] Redis authentication, expiry, no-eviction, restart and credential handling")
    finally:
        cleanup_errors = []
        for container in reversed(CONTAINERS):
            try:
                docker("rm", "-f", container)
            except (subprocess.SubprocessError, OSError):
                cleanup_errors.append(container)
        if cleanup_errors:
            raise RuntimeError("Synthetic Redis cleanup failed for: " + ", ".join(cleanup_errors))
