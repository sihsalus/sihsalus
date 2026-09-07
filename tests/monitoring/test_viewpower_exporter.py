import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "viewpower_exporter", ROOT / "monitoring" / "ups" / "viewpower_exporter.py"
)
assert SPEC and SPEC.loader
EXPORTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXPORTER)


class ViewPowerExporterTest(unittest.TestCase):
    def test_device_from_tree_matches_viewpower_usb_name(self):
        tree = [
            {"id": "11", "name": "host"},
            {"id": "111", "name": "USB (id=usbdev1_P01)"},
        ]
        self.assertEqual(EXPORTER.ViewPowerClient.device_from_tree(tree), "USBusbdev1")

    def test_render_metrics_converts_and_labels_live_values(self):
        monitor = {
            "workInfo": {
                "batteryCapacity": 93,
                "batteryRemainTime": 411,
                "batteryVoltage": "082.0",
                "outputLoadPercent": "002",
                "inputVoltage": "223.4",
                "outputVoltage": "219.1",
                "inputFrequency": "60.0",
                "outputFrequency": "60.0",
                "outputCurrent": "0.0",
                "temperatureView": "28.0",
                "warnings": [],
                "workMode": "Line mode",
            }
        }
        identity = {
            "identity": {
                "upsModelName": "OLHV2K0 ",
                "morphological": "on-line",
                "ioPhase": "1/1",
                "fwVersion": "01955.0501",
            }
        }

        metrics = EXPORTER.render_metrics(monitor, identity, 1000.0, 0.25)

        self.assertIn("sihsalus_ups_battery_charge_percent 93", metrics)
        self.assertIn("sihsalus_ups_battery_runtime_seconds 24660", metrics)
        self.assertIn("sihsalus_ups_battery_voltage_volts 82", metrics)
        self.assertIn("sihsalus_ups_load_percent 2", metrics)
        self.assertIn("sihsalus_ups_on_battery 0", metrics)
        self.assertIn('sihsalus_ups_status_info{mode="Line mode"} 1', metrics)
        self.assertIn('sihsalus_ups_info{model="OLHV2K0",topology="on-line",phase="1/1",firmware="01955.0501"} 1', metrics)

    def test_configured_device_still_initializes_the_http_session(self):
        client = EXPORTER.ViewPowerClient("http://viewpower.test/ViewPower", 1, "USBusbdev1")
        calls = []

        def request(path, form=None):
            calls.append((path, form))
            responses = {
                "isInitialized": "data:SYSTEM_INITIALIZED",
                "monitor": "<html></html>",
                "workstatus/reqMonitorData": '{"workInfo":{"workMode":"Line mode"}}',
                "queryUpsInfo": '{"identity":{"upsModelName":"test"}}',
            }
            return responses[path]

        client._request = request
        client.collect()

        self.assertEqual(calls[0][0], "isInitialized")
        self.assertEqual(calls[1][0], "monitor")
        self.assertEqual(calls[2], ("workstatus/reqMonitorData", {"portName": "USBusbdev1"}))

    def test_battery_mode_and_warning_are_exposed(self):
        monitor = {
            "workInfo": {
                "batteryCapacity": 18,
                "batteryRemainTime": 10,
                "warnings": ["low battery"],
                "workMode": "Battery mode",
            }
        }
        metrics = EXPORTER.render_metrics(monitor, None, 1000.0, 0.25)
        self.assertIn("sihsalus_ups_on_battery 1", metrics)
        self.assertIn("sihsalus_ups_warning_count 1", metrics)

    def test_missing_work_info_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "workInfo"):
            EXPORTER.render_metrics({}, None, 1000.0, 0.25)


if __name__ == "__main__":
    unittest.main()
