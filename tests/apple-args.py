#!/usr/bin/env python3
"""Exercise the build entry point, stopping at GN before compiling V8."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class AppleArgs(unittest.TestCase):
    def args_for(self, variant):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            gn = directory / 'gn'
            gn.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$ARGS_CAPTURE"\nexit 77\n')
            gn.chmod(0o755)
            env = dict(os.environ, PATH=tmp + ':' + os.environ['PATH'], ARGS_CAPTURE=str(directory / 'args'))
            result = subprocess.run([str(ROOT / 'scripts/matrix/build-ios.sh'), '--variant', variant, '--v8-dir', tmp], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 77, result.stderr)
            return (directory / 'args').read_text()

    def test_tvos_is_release_jitless_and_without_wasm(self):
        for variant, environment in [('arm64-tvdevice', 'device'), ('arm64-tvsimulator', 'simulator')]:
            args = self.args_for(variant)
            for flag in ['target_platform="tvos"', 'use_blink=true', 'v8_enable_drumbrake=false', 'v8_enable_webassembly=false', 'is_debug=false', 'v8_enable_lite_mode=true', f'target_environment="{environment}"']:
                self.assertIn(flag, args)

    def test_ios_and_catalyst_do_not_receive_tvos_overrides(self):
        for variant in ['arm64-device', 'arm64-simulator', 'x64-simulator', 'arm64-catalyst', 'x64-catalyst']:
            args = self.args_for(variant)
            self.assertNotIn('target_platform=', args)
            self.assertNotIn('use_blink=', args)
            self.assertNotIn('v8_enable_drumbrake=', args)
            self.assertIn('is_debug=false', args)
            self.assertEqual('v8_enable_lite_mode=true' in args, 'catalyst' not in variant)

if __name__ == '__main__':
    unittest.main()
