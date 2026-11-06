#!/usr/bin/env python3
"""Run uninstall under a scratch HOME with all macOS commands stubbed."""
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest


class UninstallSettings(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="naiwa uninstall ")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.app = self.home / "Applications/Naiwa.app"
        self.binary = self.app / "Contents/MacOS/naiwa"
        self.binary.parent.mkdir(parents=True)
        self.binary.write_text('''#!/bin/bash
if [ "$1" = hooks ]; then
    printf '%s' "${NAIWA_CLAUDE_SETTINGS-<unset>}" > "$HOME/selected-path"
    exit "${HOOK_EXIT:-0}"
fi
exit 0
''')
        self.binary.chmod(0o755)
        self.stubdir = self.home / "stubs"
        self.stubdir.mkdir()
        for name in ("launchctl", "defaults"):
            stub = self.stubdir / name
            stub.write_text('#!/bin/bash\nprintf "%s\\n" "$0 $*" >> "$HOME/system-actions"\n')
            stub.chmod(0o755)
        self.settings = self.home / ".claude/settings.json"
        self.settings.parent.mkdir()
        self.settings.write_text("{}\n")
        self.link = self.home / ".local/bin/naiwa"
        self.link.parent.mkdir(parents=True)
        self.link.symlink_to(self.binary)
        self.plist = self.home / "Library/LaunchAgents/com.nwverse.naiwa.plist"
        self.plist.parent.mkdir(parents=True)
        self.plist.write_text("test")
        self.config = self.home / ".config/naiwa/config.json"
        self.config.parent.mkdir(parents=True)
        self.config.write_text("{}")
        self.script = Path(__file__).resolve().parents[1] / "scripts/uninstall.sh"

    def run_script(self, override=None, failure=False):
        env = dict(os.environ, HOME=str(self.home), HOOK_EXIT="1" if failure else "0")
        env["PATH"] = str(self.stubdir) + ":/usr/bin:/bin"
        env.pop("NAIWA_CLAUDE_SETTINGS", None)
        if override is not None:
            env["NAIWA_CLAUDE_SETTINGS"] = override
        return subprocess.run(["/bin/bash", str(self.script)], env=env, capture_output=True, timeout=10)

    def assert_kept(self):
        self.assertTrue(self.app.exists())
        self.assertTrue(self.link.is_symlink())
        self.assertTrue(self.plist.exists())
        self.assertTrue(self.config.exists())
        self.assertFalse((self.home / "system-actions").exists())

    def test_unset_override_passes_selected_default_to_binary(self):
        self.assertEqual(self.run_script(failure=True).returncode, 1)
        self.assertEqual((self.home / "selected-path").read_text(), str(self.settings))
        self.assert_kept()

    def test_empty_override_passes_selected_default_to_binary(self):
        self.assertEqual(self.run_script(override="", failure=True).returncode, 1)
        self.assertEqual((self.home / "selected-path").read_text(), str(self.settings))
        self.assert_kept()

    def test_custom_override_is_passed_unchanged(self):
        custom = self.home / "custom settings.json"
        custom.write_text("{}\n")
        self.assertEqual(self.run_script(override=str(custom), failure=True).returncode, 1)
        self.assertEqual((self.home / "selected-path").read_text(), str(custom))
        self.assert_kept()

    def test_missing_custom_file_skips_hook_and_removes_app(self):
        result = self.run_script(override=str(self.home / "missing.json"), failure=True)
        self.assertEqual(result.returncode, 0)
        self.assertFalse((self.home / "selected-path").exists())
        self.assertFalse(self.app.exists())

    def test_hook_success_removes_app(self):
        self.assertEqual(self.run_script().returncode, 0)
        self.assertFalse(self.app.exists())
        self.assertFalse(self.link.is_symlink())

    @unittest.skipUnless(os.environ.get("NAIWA_TEST_REAL_BINARY"), "set NAIWA_TEST_REAL_BINARY to an isolated Hooks-only executable")
    def test_real_hooks_refuses_bad_files_without_deleting_app(self):
        # Always pass an explicit scratch override: fake HOME alone is not safe with macOS Foundation.
        shutil.copyfile(os.environ["NAIWA_TEST_REAL_BINARY"], self.binary)
        self.binary.chmod(0o755)
        for content in (b"{broken", b'{"model":"\xff"}'):
            with self.subTest(content=content):
                self.settings.write_bytes(content)
                result = self.run_script(override=str(self.settings))
                self.assertEqual(result.returncode, 1)
                self.assertEqual(self.settings.read_bytes(), content)
                self.assert_kept()
        self.settings.write_text("{}\n")
        self.settings.chmod(0)
        try:
            result = self.run_script(override=str(self.settings))
            self.assertEqual(result.returncode, 1)
            self.assert_kept()
        finally:
            self.settings.chmod(0o600)

    def test_failure_advice_covers_content_and_permissions(self):
        result = self.run_script(failure=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("格式或读取权限", result.stderr.decode())
        self.assert_kept()


if __name__ == "__main__":
    unittest.main()
