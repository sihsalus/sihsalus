"""Verify the pinned Orthanc image and real gateway using an empty tmpfs PACS.

This never starts a repository Compose project or mounts its data volumes.
Authorization itself is exercised separately by auth-gateway.sh.
"""

from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


ROOT = Path(__file__).resolve().parents[2]
PREFIX = "sihsalus-orthanc-test-" + uuid.uuid4().hex
NETWORK = PREFIX + "-network"
NGINX = "nginx:1.28-alpine"
CONTAINERS = []
NETWORK_CREATED = False


def docker(*arguments, check=True, timeout=30, **kwargs):
    return subprocess.run(
        ["docker", *arguments], check=check, capture_output=True, text=True,
        timeout=timeout, **kwargs
    )


def start_container(role, *arguments):
    container = docker(
        "create", "--name", PREFIX + "-" + role, "--network", NETWORK,
        *arguments, timeout=300,
    ).stdout.strip()
    CONTAINERS.append(container)
    docker("start", container)
    return container


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


CLIENT = urllib.request.build_opener(NoRedirect())


def request(base, path, *, method="GET", data=None):
    outgoing = urllib.request.Request(
        base + path, method=method, data=data,
        headers={"Content-Type": "application/json"} if data is not None else {},
    )
    try:
        response = CLIENT.open(outgoing, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, response.headers, response.read()


def get_json(base, path):
    status, _, body = request(base, path)
    assert status == 200, (path, status)
    return json.loads(body)


class ExplorerAssets(HTMLParser):
    def __init__(self):
        super().__init__()
        self.assets = []
        self.inline = []
        self.script = None

    def handle_starttag(self, tag, attributes):
        attributes = dict(attributes)
        if tag == "script":
            self.script = [] if "src" not in attributes else None
            if "src" in attributes:
                self.assets.append(attributes["src"])
        elif tag == "link" and attributes.get("rel") in ("stylesheet", "modulepreload", "icon"):
            self.assets.append(attributes["href"])

    def handle_data(self, data):
        if self.script is not None:
            self.script.append(data)

    def handle_endtag(self, tag):
        if tag == "script" and self.script is not None:
            self.inline.append("".join(self.script))
            self.script = None


def exercise(directory):
    global NETWORK_CREATED
    # Read the actual service image/configuration without loading any .env or
    # running Compose. This tiny companion only declares its named volume.
    companion = directory / "compose.json"
    companion.write_text(json.dumps({"volumes": {"orthanc-data": {}}}))
    environment = {key: os.environ[key] for key in ("PATH", "HOME") if key in os.environ}
    rendered = docker(
        "compose", "--env-file", "/dev/null", "--project-directory", str(ROOT),
        "-f", str(ROOT / "compose/imaging.yml"), "-f", str(companion),
        "--profile", "imaging", "config", "--format", "json", env=environment,
    )
    orthanc = json.loads(rendered.stdout)["services"]["orthanc"]
    assert orthanc["image"] == "orthancteam/orthanc:25.8.2"
    configuration = orthanc["environment"]["ORTHANC_JSON"]
    parsed_configuration = json.loads(configuration)
    assert parsed_configuration["RegisteredUsers"] == {}
    assert parsed_configuration["AuthenticationEnabled"] is False

    docker("network", "create", NETWORK)
    NETWORK_CREATED = True
    pacs = start_container(
        "pacs", "--network-alias", "orthanc",
        "--tmpfs", "/var/lib/orthanc/db:rw,noexec,nosuid,size=128m",
        "-e", "ORTHANC_JSON=" + configuration,
        "-v", str(ROOT / "imaging/orthanc-healthcheck.py") + ":/opt/sihsalus/orthanc-healthcheck.py:ro",
        orthanc["image"],
    )
    for _ in range(60):
        if docker("exec", pacs, "python3", "/opt/sihsalus/orthanc-healthcheck.py", check=False).returncode == 0:
            break
        time.sleep(1)
    else:
        raise AssertionError("The empty Orthanc PACS did not become healthy")

    start_container(
        "proxy", "--network-alias", "orthanc-proxy",
        "-v", str(ROOT / "gateway/orthanc-proxy.conf") + ":/etc/nginx/conf.d/default.conf:ro",
        "--entrypoint", "nginx", NGINX, "-g", "daemon off;",
    )
    gateway = start_container(
        "gateway", "-p", "127.0.0.1::80", "-e", "FRAME_ANCESTORS=",
        "-e", "IMAGING_ACCESS_CONTROL=allow all;", "-e", "IMAGING_NETWORK_ACCESS_CONTROL=allow all;",
        "-v", str(ROOT / "gateway") + ":/etc/nginx/includes:ro",
        "-v", str(ROOT / "gateway/nginx.conf") + ":/etc/nginx/nginx.conf:ro",
        "-v", str(ROOT / "gateway/templates") + ":/etc/nginx/conf-templates:ro",
        "-v", str(ROOT / "gateway/docker-entrypoint.sh") + ":/usr/local/bin/docker-entrypoint.sh:ro",
        "--entrypoint", "/usr/local/bin/docker-entrypoint.sh", NGINX, "nginx", "-g", "daemon off;",
    )
    port = docker("port", gateway, "80/tcp").stdout.strip().rsplit(":", 1)[1]
    base = "http://127.0.0.1:" + port
    for _ in range(30):
        try:
            if request(base, "/health")[0] == 200:
                break
        except (urllib.error.URLError, ConnectionError, TimeoutError):
            # Docker can publish the port before Nginx has completed template
            # generation. A reset/timeout during this bounded startup wait is
            # transient; subsequent PACS assertions do not suppress errors.
            pass
        time.sleep(1)
    else:
        raise AssertionError("The isolated gateway did not become healthy")

    assert get_json(base, "/orthanc/system")["Version"] == "1.12.9"
    assert get_json(base, "/orthanc/plugins/dicom-web")["Version"] == "1.21"
    assert get_json(base, "/orthanc/plugins/orthanc-explorer-2")["Version"] == "1.9.0"
    assert get_json(base, "/orthanc/studies") == []
    status, headers, _ = request(base, "/orthanc/")
    assert status in (301, 302, 307, 308)
    assert urllib.parse.urljoin("/orthanc/", headers["Location"]) == "/orthanc/ui/app/"
    status, headers, _ = request(base, "/orthanc/ui/app?label=a%26b&view=study")
    assert status == 301
    assert headers["Location"] == "/orthanc/ui/app/?label=a%26b&view=study"

    status, headers, body = request(base, "/orthanc/ui/app/")
    assert status == 200 and "text/html" in headers["Content-Type"]
    policy = headers["Content-Security-Policy"]
    assert "script-src 'self';" in policy and "style-src 'self' 'unsafe-inline';" in policy
    assets = ExplorerAssets()
    assets.feed(body.decode("utf-8"))
    assert assets.assets, "Explorer must ship its real application assets"
    # The only blocked inline code in OE2 1.9.0 adds /app's trailing slash.
    # The gateway already performs that redirect. Fail if upstream adds any
    # executable bootstrap that the strict policy would silently block.
    assert len(assets.inline) == 1
    redundant_redirect = re.sub(r"//[^\n]*", "", assets.inline[0])
    redundant_redirect = re.sub(r"\s+", "", redundant_redirect)
    assert redundant_redirect == (
        'constcurrentUri=newURL(window.location.href);'
        'if(currentUri.pathname.endsWith("app")){currentUri.pathname+="/";'
        'window.location.href=currentUri.toString();}'
    )
    for asset in assets.assets:
        resolved = urllib.parse.urljoin("/orthanc/ui/app/", asset)
        assert resolved.startswith("/orthanc/ui/app/"), asset
        status, headers, content = request(base, resolved)
        assert status == 200 and content, (asset, status)
        assert "text/html" not in headers["Content-Type"], asset

    options = get_json(base, "/orthanc/ui/api/configuration")["UiOptions"]
    for option in ("EnableUpload", "EnableDeleteResources", "EnableDicomModalities", "EnableAnonymization",
                   "EnableModification", "EnableSendTo", "EnableSettings", "EnableEditLabels", "EnableShares",
                   "EnableAddSeries", "EnableLinkToLegacyUi"):
        assert options[option] is False, option
    assert options["EnableOpenInOhifViewer3"] is True
    assert options["OhifViewer3PublicRoot"] == "/imaging/"

    query = b'{"Level":"Study","Query":{}}'
    for endpoint, payload, expected in (
        ("find", query, []), ("count-resources", query, {"Count": 0}),
        ("lookup", b"SYNTHETIC-NONEXISTENT-ID", []),
    ):
        status, _, body = request(base, "/orthanc/tools/" + endpoint, method="POST", data=payload)
        assert status == 200 and json.loads(body) == expected, (endpoint, status)
    for path in ("/dicom-web/studies?limit=1", "/imaging/dicom-web/studies?limit=1"):
        status, _, body = request(base, path)
        assert status == 204 or (status == 200 and json.loads(body) == []), (path, status)
    for path, method in (("/orthanc/instances", "POST"), ("/orthanc/tools/reset", "POST"),
                         ("/orthanc/studies/synthetic", "DELETE"), ("/dicom-web/studies", "POST"),
                         ("/imaging/dicom-web/studies", "POST"), ("/wado", "POST")):
        assert request(base, path, method=method, data=b"synthetic")[0] == 403, path
    assert get_json(base, "/orthanc/studies") == []


if __name__ == "__main__":
    try:
        with tempfile.TemporaryDirectory(prefix=PREFIX) as temporary:
            exercise(Path(temporary))
        print("[OK] Real Orthanc plugins, Explorer assets, empty queries and gateway mutation guards")
    finally:
        cleanup_errors = []
        for container in reversed(CONTAINERS):
            try:
                docker("rm", "-f", "-v", container)
            except (subprocess.SubprocessError, OSError):
                cleanup_errors.append(container)
        if NETWORK_CREATED:
            try:
                docker("network", "rm", NETWORK)
            except (subprocess.SubprocessError, OSError):
                cleanup_errors.append(NETWORK)
        if cleanup_errors:
            raise RuntimeError("Isolated Orthanc cleanup failed for: " + ", ".join(cleanup_errors))
