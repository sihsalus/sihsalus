#!/usr/bin/env python3
"""Exercise the actual Bash readiness probe against a synthetic HTTP socket."""

from pathlib import Path
import socket
import subprocess
import threading
import unittest


PROBE = Path(__file__).resolve().parents[2] / "keycloak" / "healthcheck.sh"


class KeycloakReadiness(unittest.TestCase):
    def probe(self, status):
        received = []
        errors = []
        with socket.socket() as server:
            server.bind(("127.0.0.1", 0))
            server.listen(1)
            server.settimeout(5)

            def respond():
                try:
                    connection, _ = server.accept()
                    with connection:
                        connection.settimeout(5)
                        request = b""
                        while b"\r\n\r\n" not in request:
                            chunk = connection.recv(1024)
                            if not chunk:
                                break
                            request += chunk
                        received.append(request)
                        connection.sendall(status)
                except Exception as error:
                    errors.append(error)

            worker = threading.Thread(target=respond, daemon=True)
            worker.start()
            result = subprocess.run(
                ["bash", str(PROBE), str(server.getsockname()[1])],
                capture_output=True, timeout=8,
            )
            worker.join(6)
            self.assertFalse(worker.is_alive(), "synthetic HTTP server did not finish")
            self.assertEqual(errors, [])
        self.assertEqual(received, [b"HEAD /health/ready HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"])
        return result.returncode

    def test_only_successful_http_readiness_is_healthy(self):
        for status in (b"HTTP/1.1 200 OK\r\n", b"HTTP/1.0 200 Ready\r\n", b"HTTP/1.1 200 \r\n"):
            with self.subTest(status=status):
                self.assertEqual(self.probe(status), 0)

    def test_listening_socket_and_nonready_responses_are_unhealthy(self):
        for status in (b"", b"HTTP/1.1 503 Service Unavailable\r\n",
                       b"HTTP/1.1 404 Not Found\r\n", b"HTTP/1.1 302 Found\r\n",
                       b"HTTP/1.1 2000 Invalid\r\n", b"unrelated service\r\n"):
            with self.subTest(status=status):
                self.assertNotEqual(self.probe(status), 0)

    def test_invalid_port_is_rejected_before_connecting(self):
        for port in ("0", "65536", "-1", "not-a-port", "9000/health"):
            with self.subTest(port=port):
                result = subprocess.run(["bash", str(PROBE), port], capture_output=True, timeout=2)
                self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
