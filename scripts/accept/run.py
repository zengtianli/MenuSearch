#!/usr/bin/env python3
"""Fixed acceptance checks for MenuSearch: functionality | recovery | privacy | native_ui.

Each check builds the current source once (ad-hoc signed, cached by source hash under build/accept/, including the
logic tests and the offscreen self-test) and then drives that copy's own command line with a throwaway support
directory. Nothing touches build/MenuSearch.app, /Applications, the user's settings, real shortcuts, login items or
other applications' menus, and nothing is shown on screen.

What these checks cannot show: a real shortcut reaching the panel, a command executed in another application,
real input-method composition, and how the panel looks on screen. Those need the real desktop.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
VENDORED = {"AppLifecycle.swift", "AppConfiguration.swift", "AppLifecycleUI.swift", "LaneSignal.swift"}
VENDOR = Path(os.environ.get("APP_LIFECYCLE_VENDOR") or Path.home() / "Dev/tools/dev/lib/tools/macapp/swift-shared/vendor-lifecycle.py")


def source_hash():
    files = sorted([*ROOT.glob("Sources/*.swift"), *ROOT.glob("Resources/*"), *ROOT.glob("Tests/*"),
                    ROOT / "Info.plist", ROOT / "build.sh", ROOT / "icon/AppIcon.icns", Path(__file__)])
    digest = hashlib.sha256()
    for path in files:
        digest.update(path.relative_to(ROOT).as_posix().encode() + b"\0" + path.read_bytes())
    return digest.hexdigest()[:16]


def build():
    """The cached acceptance copy of the current source; built under a lock so parallel checks share it."""
    (ROOT / "build/accept").mkdir(parents=True, exist_ok=True)
    with open(ROOT / "build/accept/.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if VENDOR.is_file():  # the build would do this; doing it first keeps the hash stable
            subprocess.run([sys.executable, str(VENDOR), "--platform", "mac", "--target-source-dir", str(ROOT / "Sources")],
                           check=True, capture_output=True)
        cache = ROOT / "build/accept" / source_hash()
        exe = cache / "MenuSearch.app/Contents/MacOS/MenuSearch"
        if not exe.exists():
            result = subprocess.run(["bash", "build.sh"], cwd=ROOT, capture_output=True, text=True,
                                    env={**os.environ, "MENUSEARCH_OUT": str(cache), "CODESIGN_IDENTITY": "-"})
            if result.returncode or not exe.exists():
                sys.stderr.write(result.stdout[-3000:] + result.stderr[-3000:])
                raise SystemExit("build failed")
    return cache, exe


class Sandbox:
    def __init__(self, exe):
        self.exe = exe
        self.work = Path(tempfile.mkdtemp(prefix="menusearch-accept."))
        self.support = self.work / "support"
        self.env = {**os.environ, "MENUSEARCH_SUPPORT_DIR": str(self.support), "APP_LIFECYCLE_SUPPORT_DIR": str(self.work / "lifecycle")}

    def run(self, *args, exe=None):
        return subprocess.run([str(exe or self.exe), *args], env=self.env, capture_output=True, text=True, timeout=30,
                              stdin=subprocess.DEVNULL)

    def json(self, *args):
        result = self.run(*args, "--json")
        try:
            return result.returncode, json.loads(result.stdout)
        except ValueError:
            return result.returncode, {"_unparsed": result.stdout, "_stderr": result.stderr}

    def files(self):
        return sorted(p.name for p in self.support.iterdir()) if self.support.is_dir() else []

    def close(self):
        shutil.rmtree(self.work, ignore_errors=True)


def self_test(cache):
    return json.loads((cache / "self-test/self-test.json").read_text())


def named(report, names):
    """Self-test checks by name; a name the build no longer reports counts as failed."""
    return {name: report["checks"].get(name) is True for name in names}


def functionality(cache, exe, box):
    info = plistlib.loads((cache / "MenuSearch.app/Contents/Info.plist").read_bytes())
    checks = {}
    version = box.run("version")
    checks["version_matches_bundle"] = version.returncode == 0 and version.stdout.strip() == f'{info["CFBundleShortVersionString"]} ({info["CFBundleVersion"]})'
    helps = [box.run(flag) for flag in ("help", "--help", "-h")]
    checks["help_lists_every_command"] = all(h.returncode == 0 and h.stdout == helps[0].stdout for h in helps) and all(
        word in helps[0].stdout for word in ("status", "show", "scan", "execute", "settings", "config", "quit", "退出码"))
    unknown = box.run("search-everything")
    checks["unknown_command_is_usage_error"] = unknown.returncode == 2 and unknown.stdout == "" and "未知命令" in unknown.stderr
    link = box.work / "menusearch"
    link.symlink_to(exe)
    bare = box.run(exe=link)
    checks["command_name_alone_prints_usage"] = bare.returncode == 0 and "用法：menusearch" in bare.stdout
    linked = box.run("version", exe=link)
    checks["link_resolves_real_bundle"] = linked.stdout == version.stdout
    code, status = box.json("status")
    checks["status_is_read_only"] = (code == 0 and status.get("ok") is True and status.get("isolated") is True
                                     and status.get("resident") == {"running": False} and status.get("mode") == "builtin"
                                     and status.get("hotkey") is None and not box.support.exists())
    refusals = [box.json(*args) for args in (["show"], ["scan"], ["scan", "--pid", "1"], ["settings"], ["quit"],
                                              ["execute", "--pid", "1", "--path-json", '["File","Close"]'])]
    checks["isolation_refuses_real_actions"] = all(c == 1 and "隔离" in r.get("error", "") for c, r in refusals) and not box.support.exists()
    usage = [box.run(*args) for args in (["scan", "--pid", "abc"], ["execute", "--pid", "1"], ["execute", "--path-json", "[]"],
                                         ["execute", "--pid", "1", "--path-json", "not json"], ["execute", "--pid", "1", "--path-json", "[]"],
                                         ["config"], ["config", "set", "mode"], ["config", "set", "colour", "blue"], ["status", "extra"])]
    checks["bad_arguments_are_usage_errors"] = all(u.returncode == 2 for u in usage)
    code, reply = box.json("config", "set", "hotkey", "alt+m")
    _, got = box.json("config", "get")
    checks["config_set_hotkey"] = code == 0 and reply.get("ok") is True and got.get("hotkey") == {"display": "⌥M", "key": "alt+m"}
    code, _ = box.json("config", "set", "mode", "external")
    _, got = box.json("config", "get")
    checks["config_set_mode"] = code == 0 and got.get("mode") == "external" and got.get("hotkey", {}).get("key") == "alt+m"
    bad = [box.json("config", "set", "hotkey", "m"), box.json("config", "set", "mode", "sometimes"), box.json("config", "set", "login", "on")]
    _, after = box.json("config", "get")
    checks["invalid_values_change_nothing"] = all(c == 1 and r.get("ok") is False for c, r in bad) and after == got
    exported = box.work / "export.json"
    checks["config_export"] = box.run("config", "export", str(exported)).returncode == 0 and exported.is_file()
    box.run("config", "set", "hotkey", "none"); box.run("config", "set", "mode", "builtin")
    _, changed = box.json("config", "get")
    imported = box.run("config", "import", str(exported))
    _, restored = box.json("config", "get")
    checks["config_import_restores"] = changed.get("hotkey") is None and imported.returncode == 0 and restored == got
    path = box.run("config", "path")
    # Compared as resolved paths: under /private/tmp the application reports the same file as /tmp/….
    checks["config_path"] = path.returncode == 0 and Path(path.stdout.strip()).resolve() == (box.support / "settings.json").resolve()
    report = self_test(cache)
    checks.update(named(report, [
        "empty_lists_all", "header_names_target", "distinct_duplicate_paths", "fuzzy_multi_token", "path_search", "chinese",
        "disabled_not_executed", "nothing_selected_not_executed", "enter_dispatch", "down_browses", "up_browses", "editing_preserved",
        "ime_return_preserved", "ime_escape_preserved", "no_match_is_stated", "fresh_dynamic_titles", "esc_closes_panel_only",
        "first_run_has_no_hotkey", "hotkey_set_registers", "builtin_close_keeps_listening", "panel_reusable_after_close",
        "close_releases_menu_data", "own_window_is_not_a_target", "second_call_closes", "external_stops_shortcut_source",
        "external_exits_after_panel", "settings_window_keeps_process", "external_exits_after_settings", "builtin_switch_registers",
        "hotkey_clear", "login_needs_builtin", "external_turns_login_off", "instance_lock_acquired", "second_instance_refused",
        "socket_status", "socket_config_applies", "socket_bad_requests_rejected", "socket_show_rejects_own_window",
        "combo_forms_agree", "combo_needs_modifier", "combo_round_trip", "registry_conflict_reported", "skhd_binding_reported",
        "registry_declares_only_active_key", "tuning_override_applies", "tuning_shipped_file_read", "filter_1000_within_budget"]))
    return checks, {"filter": report["metrics"].get("filter")}


def recovery(cache, exe, box):
    checks = {}
    box.support.mkdir(parents=True)
    settings = box.support / "settings.json"
    settings.write_text("{ not json")
    code, status = box.json("status")
    checks["damaged_settings_reported"] = code == 0 and bool(status.get("settings_error")) and status.get("mode") == "builtin" and settings.read_text() == "{ not json"
    code, _ = box.json("config", "set", "mode", "external")
    _, got = box.json("config", "get")
    kept = [name for name in box.files() if name.startswith("settings.corrupt-")]
    checks["damaged_settings_kept_on_repair"] = (code == 0 and got.get("mode") == "external" and got.get("settings_error") is None
                                                 and len(kept) == 1 and (box.support / kept[0]).read_text() == "{ not json")
    before = settings.read_bytes()
    invalid = box.work / "invalid.json"
    invalid.write_text(json.dumps({"version": 1, "product": "cyou.tianli.menusearch", "values": {"file.0.mode": "sometimes"}}))
    foreign = box.work / "foreign.json"
    foreign.write_text(json.dumps({"version": 1, "product": "cyou.tianli.mackit", "values": {"file.0.mode": "builtin"}}))
    extra = box.work / "extra.json"
    extra.write_text(json.dumps({"version": 1, "product": "cyou.tianli.menusearch", "values": {"file.0.login": True}}))
    garbage = box.work / "garbage.json"
    garbage.write_text("not a configuration")
    rejected = [box.run("config", "import", str(p)) for p in (invalid, foreign, extra, garbage, box.work / "missing.json")]
    checks["bad_imports_rejected_settings_kept"] = all(r.returncode == 1 for r in rejected) and settings.read_bytes() == before
    blocked = Sandbox(exe)
    try:
        blocked.support.parent.mkdir(parents=True, exist_ok=True)
        blocked.support.write_text("a file where the directory should be")
        code, reply = blocked.json("config", "set", "hotkey", "alt+m")
        checks["unwritable_store_reports_failure"] = code == 1 and reply.get("ok") is False and blocked.support.read_text().startswith("a file")
    finally:
        blocked.close()
    report = self_test(cache)
    checks.update(named(report, [
        "refused_hotkey_keeps_previous", "system_hotkey_refused", "failed_builtin_switch_rolls_back", "unsaved_change_not_applied",
        "damaged_settings_fall_back", "damaged_settings_are_kept", "unknown_fields_survive", "invalid_mode_falls_back",
        "incomplete_is_stated", "exited_target_rejected", "socket_refusal_reported", "socket_closed_is_silent",
        "config_export_import_restores", "config_import_rejects_invalid", "settings_refusal_keeps_previous", "tuning_bad_file_falls_back"]))
    return checks, {}


def privacy(cache, exe, box):
    checks = {}
    linked = subprocess.run(["otool", "-L", str(exe)], capture_output=True, text=True, check=True).stdout
    libraries = [line.split()[0] for line in linked.splitlines()[1:]]
    checks["links_only_system_libraries"] = bool(libraries) and all(l.startswith(("/System/Library/", "/usr/lib/")) for l in libraries)
    own = {p.name: p.read_text() for p in ROOT.glob("Sources/*.swift") if p.name not in VENDORED}
    # The one network client is the shared update check (an HTTPS request to GitHub Releases). The product's own
    # sources hold no client and no URL, and ask for a release in two places only: the `update` command and the
    # upgrade the user starts. Nothing checks on a timer or at launch.
    network = [n for n, text in own.items() if re.search(r"URLSession|NWConnection|CFSocketStream|https?://", text)]
    checks["own_sources_have_no_network_client"] = not network
    asks = {n: len(re.findall(r"AppUpdateChecker\.check\(", text)) for n, text in own.items()}
    checks["update_is_asked_only_on_request"] = ({n: c for n, c in asks.items() if c} == {"App.swift": 1, "CLI.swift": 1}
                                                 and len(re.findall(r"\bstartUpgrade\(\)", own["App.swift"])) == 2
                                                 and not any("checkForUpdates" in text for text in own.values()))
    code, refused = box.json("update")
    checks["isolated_update_stays_offline"] = code == 1 and "隔离" in refused.get("error", "")
    # A running copy holds no internet socket: started the way the measurement tools start it (a support directory
    # of its own, no shortcut registered, nothing on screen), then asked what it has open.
    quiet = subprocess.Popen([str(exe), "-lane_quiet", "YES", "--app-measure"], env=box.env, stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(2.5)
        sockets = subprocess.run(["lsof", "-nP", "-a", "-i", "-p", str(quiet.pid)], capture_output=True, text=True)
        checks["running_copy_holds_no_internet_socket"] = quiet.poll() is None and sockets.returncode == 1 and not sockets.stdout.strip()
    finally:
        quiet.terminate()
        try:
            quiet.wait(timeout=5)
        except subprocess.TimeoutExpired:
            quiet.kill()
    if VENDOR.is_file():
        drift = subprocess.run([sys.executable, str(VENDOR), "--platform", "mac", "--target-source-dir", str(ROOT / "Sources"), "--check"], capture_output=True)
        checks["shared_sources_unmodified"] = drift.returncode == 0
    # The shortcut is one registered combination: no event tap, no global key monitor, no synthetic input, no scripting bridge.
    listening = [n for n, text in own.items() if re.search(r"CGEvent|addGlobalMonitorForEvents|IOHIDManager|NSAppleScript|osascript|CGEventTap", text)]
    checks["no_key_logging_or_synthetic_input"] = not listening and "RegisterEventHotKey" in own["Hotkey.swift"]
    box.run("config", "set", "hotkey", "alt+m"); box.run("config", "set", "mode", "external")
    exported = json.loads(box.run("config", "export").stdout)
    checks["export_holds_only_preferences"] = (set(exported) == {"version", "product", "values"}
                                               and set(exported["values"]) == {"file.0.mode", "file.0.hotkey"}
                                               and str(Path.home()) not in json.dumps(exported))
    checks["only_settings_are_stored"] = box.files() == ["settings.json"]
    mode = (box.support / "settings.json").stat().st_mode & 0o777, box.support.stat().st_mode & 0o777
    checks["settings_private_to_user"] = mode == (0o600, 0o700)
    # What the application records about a presentation is counts and timings; menu titles never reach a file.
    recorded = re.search(r'let entry: \[String: Any\] = \[(.*?)\]\n', own["App.swift"], re.S)
    keys = set(re.findall(r'"(\w+)":', recorded.group(1))) if recorded else set()
    checks["presentation_record_has_no_menu_content"] = keys == {"at", "source", "elapsed_ms", "scan_ms", "count", "complete", "version", "build"}
    report = self_test(cache)
    checks.update(named(report, ["close_releases_menu_data", "config_export_has_only_preferences", "socket_closed_is_silent", "never_on_screen"]))
    checks["self_test_made_no_external_action"] = report.get("external_actions") == 0
    return checks, {"linked": [l.rsplit("/", 1)[-1] for l in libraries]}


def png_size(path):
    data = path.read_bytes()
    return struct.unpack(">II", data[16:24]) if data[:8] == b"\x89PNG\r\n\x1a\n" else (0, 0)


def native_ui(cache, exe, box):
    report = self_test(cache)
    out = cache / "self-test"
    checks = {"self_test_passed": report.get("ok") is True and not report.get("failed")}
    panel = [out / f"panel-{name}.png" for name in ("light", "dark", "filtered-light", "filtered-dark")]
    checks["panel_rendered_at_design_size"] = all(p.is_file() and png_size(p) == (1500, 948) and p.stat().st_size > 20_000 for p in panel)
    settings = [out / f"settings-{name}.png" for name in ("light", "dark", "recorded-light")]
    checks["settings_rendered"] = all(p.is_file() and png_size(p)[0] >= 1000 and p.stat().st_size > 20_000 for p in settings)
    checks["light_and_dark_differ"] = panel[0].read_bytes() != panel[1].read_bytes() and settings[0].read_bytes() != settings[1].read_bytes()
    checks.update(named(report, [
        "render_light", "render_dark", "render_filtered_light", "render_filtered_dark", "settings_render_light", "settings_render_dark",
        "settings_reflect_state", "settings_refusal_keeps_previous", "settings_record_applies", "header_names_target",
        "keycaps_split_modifiers", "no_match_is_stated", "incomplete_is_stated", "never_on_screen"]))
    return checks, {"images": [p.name for p in panel + settings], "self_test": str(out / "self-test.json")}


def main():
    names = {"functionality": functionality, "recovery": recovery, "privacy": privacy, "native_ui": native_ui}
    if len(sys.argv) != 2 or sys.argv[1] not in names:
        raise SystemExit("usage: run.py functionality|recovery|privacy|native_ui")
    name = sys.argv[1]
    cache, exe = build()
    box = Sandbox(exe)
    try:
        checks, extra = names[name](cache, exe, box)
    finally:
        box.close()
    failed = sorted(k for k, v in checks.items() if not v)
    detail = {"ok": not failed, "check": name, "summary": f"{len(checks) - len(failed)}/{len(checks)} 项通过" + (f"；未过：{', '.join(failed)}" if failed else ""),
              "checks": checks, "failed": failed, "build": str(cache), "environment": "当前源码的临时 ad-hoc 构建；隔离目录；不上屏、不注册真实快捷键、不读写其他 App", **extra}
    if os.environ.get("SOP_OUT_DIR"):
        Path(os.environ["SOP_OUT_DIR"], f"{name}.detail.json").write_text(json.dumps(detail, ensure_ascii=False, indent=2))
    print(json.dumps(detail, ensure_ascii=False, indent=2))
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
