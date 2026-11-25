"""Adds the Android permissions and settings this app needs.

Run from the project folder AFTER `flutter create` has made the android/ folder.
Safe to run twice.
"""
import pathlib
import re
import sys

PERMISSIONS = [
    "INTERNET",
    "ACCESS_NETWORK_STATE",
    "CHANGE_NETWORK_STATE",
    "MODIFY_AUDIO_SETTINGS",
    "RECORD_AUDIO",
    "BLUETOOTH",
    "BLUETOOTH_CONNECT",
    "ACCESS_FINE_LOCATION",
    "ACCESS_COARSE_LOCATION",
    "ACCESS_BACKGROUND_LOCATION",
    "FOREGROUND_SERVICE",
    "FOREGROUND_SERVICE_LOCATION",
    "POST_NOTIFICATIONS",
    "WAKE_LOCK",
    "REQUEST_IGNORE_BATTERY_OPTIMIZATIONS",
]


def patch_manifest(path: pathlib.Path) -> None:
    text = path.read_text()
    lines = []
    for name in PERMISSIONS:
        marker = 'android.permission.%s"' % name
        if marker not in text:
            lines.append(
                '    <uses-permission android:name="android.permission.%s"/>\n' % name
            )
    if lines and "<application" in text:
        text = text.replace("<application", "".join(lines) + "    <application", 1)
    text = re.sub(r'android:label="[^"]*"', 'android:label="TalkLoc"', text, count=1)
    path.write_text(text)


def patch_gradle(path: pathlib.Path) -> bool:
    text = path.read_text()
    new = re.sub(r"minSdk\s*=\s*flutter\.minSdkVersion", "minSdk = 24", text)
    new = re.sub(r"minSdkVersion\s+flutter\.minSdkVersion", "minSdkVersion 24", new)
    if new != text:
        path.write_text(new)
        return True
    return False


def main() -> int:
    root = pathlib.Path(".")
    manifest = root / "android/app/src/main/AndroidManifest.xml"
    if not manifest.exists():
        print("AndroidManifest.xml not found. Did flutter create run?", file=sys.stderr)
        return 1
    patch_manifest(manifest)
    print("Manifest patched.")

    changed = False
    for name in ("android/app/build.gradle.kts", "android/app/build.gradle"):
        gradle = root / name
        if gradle.exists():
            changed = patch_gradle(gradle) or changed
    print("minSdk set to 24." if changed else "minSdk line not changed (check build.gradle).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
