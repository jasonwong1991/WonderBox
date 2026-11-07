import pathlib
import plistlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class ReleaseOnePackagingTests(unittest.TestCase):
    def test_stable_version_and_url_dispatch(self):
        info = plistlib.loads((ROOT / 'Sources/WonderBox/Resources/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleShortVersionString'], '1.2.4')
        self.assertEqual(info['CFBundleVersion'], '124')
        self.assertIn('wonderbox', info['CFBundleURLTypes'][0]['CFBundleURLSchemes'])

    def test_login_item_identity_and_background_mode(self):
        info = plistlib.loads((ROOT / 'Sources/WonderUninstallWatcher/Resources/Info.plist').read_bytes())
        app = plistlib.loads((ROOT / 'Sources/WonderBox/Resources/Info.plist').read_bytes())
        for key in ['CFBundleShortVersionString', 'CFBundleVersion']:
            self.assertEqual(info[key], app[key])
        self.assertEqual(info['CFBundleIdentifier'], 'com.wondercraft.WonderBox.UninstallWatcher')
        self.assertEqual(info['CFBundleExecutable'], 'WonderUninstallWatcher')
        self.assertTrue(info['LSUIElement'])
        source = (ROOT / 'Sources/WonderBox/Services/UninstallWatcherController.swift').read_text()
        self.assertIn(info['CFBundleIdentifier'], source)

    def test_updater_fallback_matches_release_metadata(self):
        info = plistlib.loads((ROOT / 'Sources/WonderBox/Resources/Info.plist').read_bytes())
        source = (ROOT / 'Sources/WonderBox/Services/UpdateController.swift').read_text()
        self.assertIn('?? "' + info['CFBundleShortVersionString'] + '"', source)
        self.assertIn('?? "' + info['CFBundleVersion'] + '"', source)

    def test_helper_is_embedded_and_signed_before_parent(self):
        source = (ROOT / 'scripts/package_app.sh').read_text()
        self.assertIn('Library/LoginItems/WonderUninstallWatcher.app/Contents', source)
        helper_sign = 'codesign --force --sign - "$CONTENTS/Library/LoginItems/WonderUninstallWatcher.app"'
        parent_sign = 'codesign --force --deep --sign - "$APP"'
        self.assertLess(source.index(helper_sign), source.index(parent_sign))
        self.assertNotIn('launchctl', source)


if __name__ == '__main__':
    unittest.main()
