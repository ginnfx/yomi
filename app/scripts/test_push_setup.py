import subprocess
import tempfile
import unittest
from pathlib import Path

from merge_push_settings import merge


class PushSetupTests(unittest.TestCase):
    def test_fresh_android_setup_and_repeated_provider_updates(self):
        with tempfile.TemporaryDirectory() as folder:
            env = Path(folder) / "push.env"
            startup = Path(folder) / "start.sh"
            startup.write_text("#!/bin/sh\ncd /data/local/tmp/yomi\nexec ./yomi-upload\n")
            merge(env, startup, ["YOMI_FCM_SERVICE_ACCOUNT=/keys/android.json"])
            merge(env, startup, ["YOMI_APNS_KEY_ID=FIRST"])
            merge(env, startup, ["YOMI_APNS_KEY_ID=SECOND"])
            self.assertIn("YOMI_FCM_SERVICE_ACCOUNT=/keys/android.json", env.read_text())
            self.assertNotIn("FIRST", env.read_text())
            self.assertEqual(env.read_text().count("YOMI_APNS_KEY_ID="), 1)
            self.assertEqual(startup.read_text().count(". ./push.env"), 1)
            subprocess.run(["sh", "-n", str(startup)], check=True)

    def test_values_are_literal_shell_data(self):
        with tempfile.TemporaryDirectory() as folder:
            env = Path(folder) / "push.env"
            startup = Path(folder) / "start.sh"
            startup.write_text("exec ./yomi-upload\n")
            value = "a space ' quote $(false)"
            merge(env, startup, [f"YOMI_APNS_TOPIC={value}"])
            result = subprocess.run(
                ["sh", "-c", '. "$1"; printf "%s" "$YOMI_APNS_TOPIC"', "sh", str(env)],
                check=True, capture_output=True, text=True,
            )
            self.assertEqual(result.stdout, value)

    def test_unknown_startup_leaves_configuration_unchanged(self):
        with tempfile.TemporaryDirectory() as folder:
            env = Path(folder) / "push.env"
            startup = Path(folder) / "start.sh"
            env.write_text("export YOMI_FCM_SERVICE_ACCOUNT=original\n")
            startup.write_text("echo unknown launcher\n")
            with self.assertRaises(ValueError):
                merge(env, startup, ["YOMI_APNS_KEY_ID=NEW"])
            self.assertEqual(env.read_text(), "export YOMI_FCM_SERVICE_ACCOUNT=original\n")


if __name__ == "__main__":
    unittest.main()
