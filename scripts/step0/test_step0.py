"""Tests for the Step 0 scripts. Uses only fake folders and a fake `security`."""
import json
import os
import sqlite3
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
UUID_A = "11111111-1111-4111-8111-111111111111"
UUID_B = "22222222-2222-4222-8222-222222222222"
ORG = "33333333-3333-4333-8333-333333333333"
WEB_STORAGE = ["Cookies", "Cookies-journal", "Local Storage", "Session Storage",
               "IndexedDB", "WebStorage", "blob_storage"]
SECRETS = ["SECRETVALUE", "COOKIEVALUE", "TOKENVALUE"]

FAKE_SECURITY = """#!/bin/bash
state="$(cat "$FAKE_KC_STATE")"
if [ "$state" = "missing" ]; then exit 44; fi
for a in "$@"; do if [ "$a" = "-w" ]; then echo "SECRETVALUE-$state"; exit 0; fi; done
echo "keychain: attributes only"
exit 0
"""


class Step0Flow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = cls.tmp.name
        cls.app = os.path.join(root, "App Support", "Claude")
        cls.home = os.path.join(root, ".claude")
        cls.cjson = os.path.join(root, ".claude.json")
        cls.out = os.path.join(root, "out")
        cls.kc = os.path.join(root, "kc-state")
        cls.sec = os.path.join(root, "security")
        os.makedirs(os.path.join(cls.app, "Local Storage"))
        os.makedirs(os.path.join(cls.app, "vm_bundles"))
        os.makedirs(os.path.join(cls.app, "claude-code-sessions", UUID_A))
        os.makedirs(os.path.join(cls.home, "skills"))
        with open(cls.sec, "w") as f:
            f.write(FAKE_SECURITY)
        os.chmod(cls.sec, 0o755)
        cls.write(os.path.join(cls.app, "Local Storage", "x"), "ls")
        with open(os.path.join(cls.app, "vm_bundles", "big"), "wb") as f:
            f.write(b"\0" * (5 * 1024 * 1024))
        cls.write(os.path.join(cls.app, "claude-code-sessions", UUID_A, "s.json"), "{}")
        cls.write(os.path.join(cls.app, "buddy-tokens.json"), '{"t":"TOKENVALUE-buddy1"}')
        cls.write(os.path.join(cls.home, "CLAUDE.md"), "hi")
        cls.write(os.path.join(cls.home, "remote-settings.json"), '{"org":"a"}')
        cls.config = {"locale": "en", "updaterLastSeenVersion": "1",
                      "oauth:tokenCache": "TOKENVALUE-a1",
                      "oauth:tokenCacheV2": {"t": "TOKENVALUE-a2"},
                      "lastKnownAccountUuid": UUID_A}
        cls.cli = {"numStartups": 1, "projects": {},
                   "oauthAccount": {"accountUuid": UUID_A, "emailAddress": "a@example.com"}}
        cls.cookies([(".claude.ai", "sessionKey"), ("claude.ai", "theme")])
        cls.set_kc("1")

        cls.snap("S1")
        cls.config["updaterLastSeenVersion"] = "2"          # noise
        cls.snap("S2")
        for k in ("oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid"):
            del cls.config[k]                                # log out
        cls.cookies([("claude.ai", "theme")])
        cls.snap("S3")
        cls.config.update({"oauth:tokenCache": "TOKENVALUE-b1",   # log in (other account)
                           "oauth:tokenCacheV2": {"t": "TOKENVALUE-b2"},
                           "lastKnownAccountUuid": UUID_B,
                           "dxt:allowlistCache:" + ORG: [1]})
        cls.cookies([(".claude.ai", "sessionKey"), ("claude.ai", "theme")])
        cls.write(os.path.join(cls.app, "buddy-tokens.json"), '{"t":"TOKENVALUE-buddy2"}')
        cls.snap("S4")
        cls.cli["numStartups"] = 2                           # CLI noise
        cls.snap("C2")
        del cls.cli["oauthAccount"]                          # CLI log out
        cls.set_kc("missing")
        os.remove(os.path.join(cls.home, "remote-settings.json"))
        cls.snap("C3")
        cls.cli["oauthAccount"] = {"accountUuid": UUID_B, "emailAddress": "b@example.com"}
        cls.set_kc("2")
        cls.write(os.path.join(cls.home, "remote-settings.json"), '{"org":"b"}')
        cls.snap("C4")

        subprocess.run([sys.executable, "-I", os.path.join(HERE, "analyze.py"), "--dir", cls.out],
                       check=True, capture_output=True)
        with open(os.path.join(cls.out, "login-set.proposed.json")) as f:
            cls.proposed = json.load(f)
        with open(os.path.join(cls.out, "report.md")) as f:
            cls.report = f.read()

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    @staticmethod
    def write(path, text):
        with open(path, "w") as f:
            f.write(text)

    @classmethod
    def set_kc(cls, state):
        cls.write(cls.kc, state)

    @classmethod
    def cookies(cls, rows):
        path = os.path.join(cls.app, "Cookies")
        if os.path.exists(path):
            os.remove(path)
        db = sqlite3.connect(path)
        db.execute("CREATE TABLE cookies(host_key, name, value, encrypted_value)")
        db.executemany("INSERT INTO cookies VALUES (?, ?, 'COOKIEVALUE', 'COOKIEVALUE-enc')", rows)
        db.commit()
        db.close()

    @classmethod
    def snap(cls, label):
        cls.write(os.path.join(cls.app, "config.json"), json.dumps(cls.config))
        cls.write(cls.cjson, json.dumps(cls.cli))
        env = dict(os.environ, FAKE_KC_STATE=cls.kc)
        result = subprocess.run(
            [sys.executable, "-I", os.path.join(HERE, "snapshot.py"), "--label", label,
             "--out-dir", cls.out, "--app-dir", cls.app, "--claude-home", cls.home,
             "--claude-json", cls.cjson, "--security", cls.sec, "--user", "tester",
             "--app-bundle", os.path.join(cls.tmp.name, "NoSuch.app")],
            env=env, capture_output=True, text=True)
        if result.returncode != 0:
            raise AssertionError(result.stderr)
        for secret in SECRETS:
            assert secret not in result.stdout + result.stderr

    def load(self, label):
        with open(os.path.join(self.out, label + ".json")) as f:
            return json.load(f)

    def test_proposed_login_set(self):
        app, cli = self.proposed["app"], self.proposed["cli"]
        self.assertEqual(app["configKeys"],
                         ["lastKnownAccountUuid", "oauth:tokenCache", "oauth:tokenCacheV2"])
        self.assertEqual(app["tokenKeys"], ["oauth:tokenCache", "oauth:tokenCacheV2"])
        self.assertEqual(app["accountIdKey"], "lastKnownAccountUuid")
        self.assertEqual(app["items"], WEB_STORAGE)
        self.assertEqual(cli["claudeJsonKeys"], ["oauthAccount"])
        self.assertEqual(cli["claudeHomeItems"], ["remote-settings.json"])
        self.assertEqual(cli["keychainService"], "Claude Code-credentials")
        self.assertEqual(self.proposed["schemaVersion"], 1)
        self.assertEqual(app["loginCookie"], {"hostSuffix": "claude.ai", "name": "sessionKey"})

    def test_noise_and_per_org_keys_excluded(self):
        keys = self.proposed["app"]["configKeys"] + self.proposed["cli"]["claudeJsonKeys"]
        for k in ("numStartups", "updaterLastSeenVersion", "dxt:allowlistCache:" + ORG):
            self.assertNotIn(k, keys)
        per_org = self.report.split("already per org")[1].split("\n## ")[0]
        self.assertIn("dxt:allowlistCache:" + ORG, per_org)

    def test_outside_files_need_a_person(self):
        section = self.report.split("Needs a person to decide")[1].split("\n## ")[0]
        self.assertIn("buddy-tokens.json", section)
        self.assertNotIn("buddy-tokens.json", self.proposed["app"]["items"])
        self.assertNotIn("claude-code-sessions", section)

    def test_report_checks(self):
        for needle in ("OK — logged-in rule", "OK — login cookies", "OK — CLI Keychain item",
                       "OK — oauthAccount", "CLI secret size"):
            self.assertIn(needle, self.report)
        self.assertNotIn("CHECK —", self.report)
        self.assertNotIn("ERROR", self.report)

    def test_no_values_leak(self):
        for name in os.listdir(self.out):
            with open(os.path.join(self.out, name)) as f:
                text = f.read()
            for secret in SECRETS + ["a@example.com", UUID_B]:
                self.assertNotIn(secret, text, name)

    def test_big_files_not_hashed(self):
        files = self.load("S1")["app"]["files"]
        self.assertIsNone(files["vm_bundles/big"]["sha"])
        self.assertEqual(files["vm_bundles/big"]["size"], 5 * 1024 * 1024)
        self.assertIsNotNone(files["buddy-tokens.json"]["sha"])
        self.assertNotIn("Cookies", files)
        self.assertNotIn("Local Storage/x", files)

    def test_snapshot_shape_and_modes(self):
        s = self.load("S1")
        self.assertEqual(s["app"]["cookies"], [".claude.ai\tsessionKey", "claude.ai\ttheme"])
        self.assertTrue(s["cli"]["keychainItemExists"])
        self.assertEqual(s["cli"]["keychainSecretBytes"], len("SECRETVALUE-1"))
        self.assertFalse(self.load("C3")["cli"]["keychainItemExists"])
        self.assertEqual(s["app"]["webStorage"]["Local Storage"], {"exists": True, "files": 1, "bytes": 2})
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(self.out, "S1.json")).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(self.out).st_mode), 0o700)


if __name__ == "__main__":
    unittest.main()
