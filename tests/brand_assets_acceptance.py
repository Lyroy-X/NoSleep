"""Check shipped macOS icon sizes/transparency and exact bundle resource identity."""
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def png_header(path):
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    width, height, depth, color = struct.unpack('>IIBB', data[16:26])
    return width, height, depth, color


class BrandAssetsAcceptance(unittest.TestCase):
    def test_source_has_square_high_resolution_alpha(self):
        width, height, _, color = png_header(ROOT / 'Resources/NoSleep-icon.png')
        self.assertEqual(width, height)
        self.assertGreaterEqual(width, 1024)
        self.assertIn(color, (4, 6), 'Icon source must retain an alpha channel')

    def test_icns_has_every_standard_and_retina_size_with_alpha(self):
        with tempfile.TemporaryDirectory(prefix='nosleep-icon-check-') as directory:
            iconset = Path(directory) / 'NoSleep.iconset'
            subprocess.run(['iconutil', '-c', 'iconset', str(ROOT / 'Resources/NoSleep.icns'),
                            '-o', str(iconset)], check=True, capture_output=True)
            for size in (16, 32, 128, 256, 512):
                for suffix, scale in (('', 1), ('@2x', 2)):
                    with self.subTest(size=size, scale=scale):
                        width, height, _, color = png_header(iconset / f'icon_{size}x{size}{suffix}.png')
                        self.assertEqual((width, height), (size * scale, size * scale))
                        self.assertIn(color, (4, 6))

    def test_built_bundle_uses_exact_approved_resource_and_version(self):
        app = Path(os.environ.get('NOSLEEP_APP', ROOT / 'build/regression/NoSleep.app'))
        source = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
        bundle = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        for key in ('CFBundleShortVersionString', 'CFBundleVersion', 'CFBundleIconFile'):
            self.assertEqual(bundle[key], source[key])
        self.assertEqual((app / 'Contents/Resources' / bundle['CFBundleIconFile']).read_bytes(),
                         (ROOT / 'Resources/NoSleep.icns').read_bytes())
        subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True, capture_output=True)


if __name__ == '__main__':
    unittest.main()
