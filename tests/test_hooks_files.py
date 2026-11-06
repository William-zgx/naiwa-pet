#!/usr/bin/env python3
"""File-handling regressions; SWIFTC may point to a Linux or macOS Swift compiler."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class HooksFiles(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which(os.environ.get("SWIFTC", "swiftc"))
        if not compiler:
            raise unittest.SkipTest("Swift compiler unavailable; set SWIFTC")
        cls.build = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.build.cleanup)
        build = Path(cls.build.name)
        (build / "main.swift").write_text(
            "import Foundation\nHooks.main(Array(CommandLine.arguments.dropFirst(2)))\n"
        )
        cls.binary = build / "naiwa"
        source = Path(__file__).resolve().parents[1] / "Sources/naiwa/Hooks.swift"
        subprocess.run([compiler, str(source), str(build / "main.swift"), "-o", str(cls.binary)], check=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def run_hooks(self, settings, action, success=True):
        env = dict(os.environ, NAIWA_CLAUDE_SETTINGS=str(settings))
        env["PATH"] = str(self.binary.parent) + os.pathsep + env.get("PATH", "")
        result = subprocess.run([str(self.binary), "hooks", action], env=env, capture_output=True, timeout=10)
        self.assertEqual(result.returncode == 0, success, result.stderr.decode(errors="replace"))
        return result

    def test_dangling_relative_and_absolute_links(self):
        for absolute in (False, True):
            with self.subTest(absolute=absolute):
                folder = self.root / str(absolute)
                folder.mkdir()
                target = folder / "dotfiles/settings.json"
                link = folder / "settings.json"
                link.symlink_to(target if absolute else "dotfiles/settings.json")
                self.run_hooks(link, "install")
                self.assertTrue(link.is_symlink())
                self.assertIn("naiwa hook", target.read_text())
                self.run_hooks(link, "uninstall")
                self.assertTrue(link.is_symlink())
                self.assertEqual(json.loads(target.read_text()), {"hooks": {}})

    def test_link_chain_with_missing_parent(self):
        link = self.root / "settings.json"
        link.symlink_to("middle.json")
        (self.root / "middle.json").symlink_to("new/dotfiles/settings.json")
        self.run_hooks(link, "install")
        self.assertTrue(link.is_symlink())
        self.assertTrue((self.root / "middle.json").is_symlink())
        self.assertIn("naiwa hook", (self.root / "new/dotfiles/settings.json").read_text())

    def test_existing_link_permissions_and_round_trip(self):
        target = self.root / "original.json"
        original = '{\n  "model": "example", "hooks": {"OtherEvent": []}\n}\n'
        target.write_text(original)
        target.chmod(0o600)
        link = self.root / "settings.json"
        link.symlink_to("original.json")
        self.run_hooks(link, "install")
        self.run_hooks(link, "uninstall")
        self.assertTrue(link.is_symlink())
        self.assertEqual(target.read_text(), original)
        # Foundation atomic writes preserve mode on macOS, but not on Linux.
        if sys.platform == "darwin":
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)

    def test_preserves_first_backup_after_settings_change(self):
        settings = self.root / "settings.json"
        original = '{"model":"first"}\n'
        settings.write_text(original)
        self.run_hooks(settings, "install")
        self.run_hooks(settings, "uninstall")
        settings.write_text('{"model":"second"}\n')
        self.run_hooks(settings, "install")
        self.assertEqual(Path(str(settings) + ".bak-naiwa").read_text(), original)
        self.assertIn('"second"', settings.read_text())

    def test_dangling_backup_is_not_replaced(self):
        settings = self.root / "settings.json"
        settings.write_text("{}\n")
        backup = Path(str(settings) + ".bak-naiwa")
        backup.symlink_to("missing-backup.json")
        self.run_hooks(settings, "install")
        self.assertTrue(backup.is_symlink())
        self.assertFalse((self.root / "missing-backup.json").exists())

    def test_cycle_and_excess_depth_fail_without_writes(self):
        for length, cycle in ((2, True), (42, False)):
            with self.subTest(length=length):
                folder = self.root / str(length)
                folder.mkdir()
                for i in range(length):
                    dest = str((i + 1) % length) if cycle else str(i + 1)
                    (folder / str(i)).symlink_to(dest)
                self.run_hooks(folder / "0", "install", success=False)
                self.assertTrue(all((folder / str(i)).is_symlink() for i in range(length)))
                self.assertFalse((folder / str(length)).exists())
                self.assertFalse(Path(str(folder / "0") + ".bak-naiwa").exists())


if __name__ == "__main__":
    unittest.main()
