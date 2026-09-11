"""Regression coverage for the metadata-only Orthanc readiness probe."""

import http.client
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import MagicMock, call, patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "orthanc_healthcheck", ROOT / "imaging" / "orthanc-healthcheck.py"
)
healthcheck = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(healthcheck)


class OrthancReadinessTest(unittest.TestCase):
    def connection(self, responses):
        connection = MagicMock()
        connection.getresponse.side_effect = responses
        return connection

    def test_ready_requires_both_core_and_dicomweb_without_patient_queries(self):
        system, plugin = MagicMock(status=200), MagicMock(status=200)
        connection = self.connection([system, plugin])
        with patch.object(http.client, "HTTPConnection", return_value=connection) as factory:
            self.assertTrue(healthcheck.is_ready())
        factory.assert_called_once_with("127.0.0.1", 8042, timeout=3)
        self.assertEqual(
            connection.request.call_args_list,
            [call("GET", "/system"), call("GET", "/plugins/dicom-web")],
        )
        system.read.assert_called_once_with()
        plugin.read.assert_called_once_with()
        connection.close.assert_called_once()

    def test_running_core_without_dicomweb_is_unhealthy(self):
        connection = self.connection([MagicMock(status=200), MagicMock(status=404)])
        with patch.object(http.client, "HTTPConnection", return_value=connection):
            self.assertFalse(healthcheck.is_ready())
        connection.close.assert_called_once()

    def test_unavailable_or_unauthorized_core_stops_the_probe(self):
        for status in (401, 403, 404, 503):
            with self.subTest(status=status):
                connection = self.connection([MagicMock(status=status)])
                with patch.object(http.client, "HTTPConnection", return_value=connection):
                    self.assertFalse(healthcheck.is_ready())
                connection.request.assert_called_once_with("GET", "/system")
                connection.close.assert_called_once()

    def test_transport_and_protocol_errors_are_unhealthy(self):
        for error in (ConnectionRefusedError(), TimeoutError(), http.client.BadStatusLine("invalid")):
            with self.subTest(error=type(error).__name__):
                connection = self.connection([error])
                with patch.object(http.client, "HTTPConnection", return_value=connection):
                    self.assertFalse(healthcheck.is_ready())
                connection.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
