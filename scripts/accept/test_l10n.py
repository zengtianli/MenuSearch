"""Native bilingual UI acceptance, using isolated production views without showing windows."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

import pytest

ROOT = Path(__file__).resolve().parents[2]
APP = Path(os.environ.get("MENUSEARCH_L10N_APP", ROOT / "build/MenuSearch.app"))
EXE = APP / "Contents/MacOS/MenuSearch"


@pytest.mark.parametrize("language,locale", [("en", "en_US"), ("zh-Hans", "zh_CN")])
def test_product_views_follow_system_language_without_untranslated_chinese(language, locale):
    assert EXE.is_file(), "Build the candidate with bash build.sh first."
    out = ROOT / "perf/acceptance/l10n" / language
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="menusearch-l10n-") as scratch:
        env = {**os.environ, "MENUSEARCH_SUPPORT_DIR": scratch + "/support",
               "APP_LIFECYCLE_SUPPORT_DIR": scratch + "/lifecycle"}
        result = subprocess.run(
            [str(EXE), "--site-shots", "--l10n-check", "--output", str(out),
             "-AppleLanguages", f"({language})", "-AppleLocale", locale],
            env=env, capture_output=True, text=True, timeout=60,
            stdin=subprocess.DEVNULL)
        assert result.returncode == 0, result.stdout + result.stderr
    report = json.loads((out / "l10n.json").read_text())
    assert report["language"] == language
    assert report["ok"] and report["offscreen"] and report["cli_error_preserved"]
    assert report["language_controls_present"] and report["language_preferences_work"]
    assert report["language_options"] == ["Follow System" if language == "en" else "跟随系统", "简体中文", "English"]
    if language == "en":
        assert report["remaining_product_chinese"] == []
        # The native language selector deliberately names Chinese in Chinese. Exempt that
        # exact label only while the shared module is byte-for-byte identical to its source.
        vendor = Path(os.environ.get("APP_LIFECYCLE_VENDOR") or Path.home() / "Dev/tools/dev/lib/tools/macapp/swift-shared/vendor-lifecycle.py")
        subprocess.run(["python3", str(vendor), "--platform", "mac", "--cli",
                        "--target-source-dir", str(ROOT / "Sources"), "--check"], check=True)
        assert report["shared_layer_chinese"] == ["简体中文"]
    else:
        # zh-Hans still resolves to the Chinese strings, not the English development language.
        assert len(report["remaining_product_chinese"]) * 2 > report["product_text_count"] // 4
    info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
    assert info["CFBundleDevelopmentRegion"] == "en"
    assert set(info["CFBundleLocalizations"]) == {"en", "zh-Hans"}
    for filename in ("panel.png", "panel-search-dark.png", "panel-empty.png",
                     "panel-permission.png", "settings.png"):
        assert (out / filename).stat().st_size > 10_000
    report["artifact"] = {"version": info["CFBundleShortVersionString"],
                          "build": info["CFBundleVersion"],
                          "executable_sha256": hashlib.sha256(EXE.read_bytes()).hexdigest()}
    (out / "l10n.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
