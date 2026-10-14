#!/usr/bin/env python3
"""Chapter basics for the installed MenuSearch: real offscreen UI and private CLI fixtures; never build/install."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
APP = Path('/Applications/MenuSearch.app')
PRODUCT = 'cyou.tianli.menusearch'
FEATURES = ('settings', 'shortcuts', 'icloud', 'updates')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write(path, body):
    path.write_text(json.dumps(body, ensure_ascii=False, indent=2) + '\n')


def input_files(patterns):
    return {path.relative_to(ROOT).as_posix() for pattern in patterns
            for path in ROOT.glob(pattern + '/*' if pattern.endswith('/**') else pattern) if path.is_file()}


def production_snapshot():
    # Hash only; never copy the user's preferences or menu content into acceptance output.
    prefs = subprocess.run(['defaults', 'export', PRODUCT, '-'], capture_output=True, timeout=10)
    settings = Path.home() / 'Library/Application Support' / PRODUCT / 'settings.json'
    return {'preferences_exit': prefs.returncode, 'preferences_sha256': hashlib.sha256(prefs.stdout).hexdigest(),
            'settings_sha256': sha(settings) if settings.is_file() else None,
            'executable_sha256': sha(APP / 'Contents/MacOS/MenuSearch')}


def main():
    spec = json.loads(os.environ['SOP_PRODUCT_BASICS_SPEC'])
    app_id = os.environ['SOP_APP_ID']
    out = Path(os.environ['SOP_OUT_DIR']).resolve()
    if app_id != 'menu-search' or spec['app_id'] != app_id or not out.is_relative_to(ROOT / 'perf/acceptance'):
        raise ValueError('This acceptance only writes MenuSearch perf/acceptance under the Chapter contract')
    run = out / ('product-basics-' + uuid.uuid4().hex)
    run.mkdir(parents=True)
    checks = {key: {} for key in FEATURES}
    cases = []
    missing = {key: [] for key in FEATURES}
    before = production_snapshot()
    receipt_path = ROOT / 'perf/build-receipt.json'
    receipt = json.loads(receipt_path.read_text())
    artifact = receipt['artifact']
    installed_info = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
    installed_sha = sha(APP / artifact['executable'])
    source_files = receipt['source']['files']
    source_mismatches = [name for name, checksum in source_files.items()
                         if not (ROOT / name).is_file() or sha(ROOT / name) != checksum]
    current_inputs = input_files(receipt['source']['input_globs'])
    source_mismatches.extend('unrecorded:' + name for name in sorted(current_inputs - set(source_files)))
    source_mismatches.extend('missing:' + name for name in sorted(set(source_files) - current_inputs))
    binding = {'installed_path': str(APP), 'bundle_id': installed_info['CFBundleIdentifier'],
               'version': installed_info['CFBundleShortVersionString'], 'build': installed_info['CFBundleVersion'],
               'executable_sha256': installed_sha, 'receipt_sha256': sha(receipt_path),
               'source_sha256': receipt['source']['sha256'], 'source_files': source_files,
               'source_mismatches': source_mismatches}
    bound = (installed_info['CFBundleIdentifier'] == artifact['bundle_id'] == PRODUCT
             and installed_info['CFBundleShortVersionString'] == artifact['version']
             and str(installed_info['CFBundleVersion']) == str(artifact['build'])
             and installed_sha == artifact['sha256'] and not source_mismatches)
    for feature in FEATURES:
        checks[feature][feature + '.installed_and_source_binding'] = bound is True

    identity = 'test.tianli.menusearch.basics.' + uuid.uuid4().hex
    clone = run / 'MenuSearch.app'
    executable = clone / artifact['executable']
    ui = {}
    env = None
    home = run / 'home'
    ui_dir = run / 'ui'
    error = None
    try:
        if not bound:
            raise ValueError('Installed executable/version or current source does not match its build receipt; no rebuild attempted')
        shutil.copytree(APP, clone, symlinks=True)
        binding['copy_before_sign_sha256'] = sha(executable)
        for feature in FEATURES:
            checks[feature][feature + '.copied_installed_binary'] = sha(executable) == installed_sha
        info_path = clone / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        info['CFBundleIdentifier'] = identity
        info_path.write_bytes(plistlib.dumps(info))
        signed = subprocess.run(['codesign', '--force', '--sign', '-', str(clone)], capture_output=True, text=True, timeout=20)
        (run / 'sign.log').write_text(signed.stdout + signed.stderr)
        if signed.returncode:
            raise ValueError('Cannot sign disposable copy: ' + signed.stderr)
        binding['test_identity'] = identity
        binding['copy_after_sign_sha256'] = sha(executable)
        home.mkdir()
        env = {**os.environ, 'HOME': str(home), 'CFFIXED_USER_HOME': str(home),
               'APP_LIFECYCLE_SUPPORT_DIR': str(run / 'lifecycle'),
               'APP_LIFECYCLE_CLOUD_DIR': str(run / 'cloud'), 'APP_LIFECYCLE_NO_RELAUNCH': '1'}
        # Product isolation blocks cloud/update mutations. A renamed copy plus a validated private home lets
        # the real shared CLI exercise fixtures without entering the user's support directory or preference domain.
        env.pop('MENUSEARCH_SUPPORT_DIR', None)

        def call(feature, name, words, predicate, code=0, isolated=False, override=None):
            process_env = {**env, **(override or {})}
            if isolated:
                process_env['MENUSEARCH_SUPPORT_DIR'] = str(settings_path.parent)
            result = subprocess.run([str(executable), *words, '--json'], env=process_env,
                                    capture_output=True, text=True, timeout=35, stdin=subprocess.DEVNULL)
            try:
                body = json.loads(result.stdout)
            except ValueError:
                body = {'unparsed': result.stdout, 'stderr': result.stderr}
            passed = result.returncode == code and predicate(body) is True
            check_key = feature + '.' + name
            checks[feature][check_key] = checks[feature].get(check_key, True) is True and passed
            cases.append({'feature': feature, 'case': name, 'arguments': words, 'isolated_product': isolated,
                          'exit': result.returncode, 'passed': passed, 'response': body})
            return body

        path_result = subprocess.run([str(executable), 'config', 'path', '--json'], env=env,
                                     capture_output=True, text=True, timeout=10)
        path_body = json.loads(path_result.stdout)
        settings_path = Path(path_body['path']).resolve()
        if path_result.returncode or not settings_path.is_relative_to(home.resolve()):
            raise ValueError('CFFIXED_USER_HOME did not isolate the actual product settings path; refusing writes')
        binding['private_settings_path'] = str(settings_path.relative_to(ROOT))
        settings_path.parent.mkdir(parents=True, exist_ok=True)

        ui_env = {**env, 'MENUSEARCH_SUPPORT_DIR': str(run / 'ui-support'),
                  'APP_LIFECYCLE_SUPPORT_DIR': str(run / 'ui-lifecycle')}
        result = subprocess.run([str(executable), '--self-test', '--output', str(ui_dir)], env=ui_env,
                                capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
        (run / 'ui.log').write_text(result.stdout + result.stderr)
        ui_path = ui_dir / 'self-test.json'
        ui = json.loads(ui_path.read_text()) if ui_path.is_file() else {}
        relevant = {
            'settings': ['settings_render_light', 'settings_render_dark', 'settings_reflect_state',
                         'settings_record_applies', 'settings_refusal_keeps_previous',
                         'config_export_import_restores', 'config_import_rejects_invalid',
                         'config_wrong_field_import_is_atomic', 'damaged_settings_are_kept'],
            'shortcuts': ['enter_dispatch', 'esc_closes_panel_only', 'combo_round_trip', 'combo_needs_modifier',
                          'hotkey_set_registers', 'hotkey_clear', 'builtin_switch_registers',
                          'refused_hotkey_keeps_previous', 'system_hotkey_refused',
                          'failed_builtin_switch_rolls_back', 'hidden_window_cannot_start_key_recording']}
        for feature, names in relevant.items():
            for name in names:
                checks[feature][feature + '.' + name] = (ui.get('checks') or {}).get(name) is True
        safe_ui = ((ui.get('checks') or {}).get('never_on_screen') is True and ui.get('external_actions') == 0
                   and ui.get('version') == artifact['version'] and str(ui.get('build')) == str(artifact['build']))
        for feature in FEATURES:
            checks[feature][feature + '.offscreen_installed_self_test'] = safe_ui is True

        call('settings', 'save', ['config', 'set', 'hotkey', 'alt+m'], lambda b: b.get('ok') is True, isolated=True)
        call('settings', 'fresh_process_readback', ['config', 'get'],
             lambda b: b.get('hotkey', {}).get('key') == 'alt+m', isolated=True)
        previous = settings_path.read_bytes()
        call('settings', 'bad_value_refused', ['config', 'set', 'hotkey', 'm'], lambda b: b.get('ok') is False, 1, True)
        checks['settings']['settings.invalid_input_preserves_file'] = settings_path.read_bytes() == previous
        exported = run / 'export.json'
        call('settings', 'export', ['config', 'export', '-o', str(exported)], lambda b: b.get('ok') is True, isolated=True)
        call('shortcuts', 'clear_saved_binding', ['config', 'set', 'hotkey', 'none'], lambda b: b.get('ok') is True, isolated=True)
        call('shortcuts', 'clear_fresh_readback', ['config', 'get'], lambda b: b.get('hotkey') is None, isolated=True)
        call('settings', 'import', ['config', 'import', str(exported), '--yes'], lambda b: b.get('imported') is True, isolated=True)
        call('shortcuts', 'restore_fresh_readback', ['config', 'get'],
             lambda b: b.get('hotkey', {}).get('key') == 'alt+m', isolated=True)

        cloud = run / 'cloud' / (PRODUCT + '.json')
        call('icloud', 'enable_and_push', ['config', 'sync', 'on', '--yes'],
             lambda b: b.get('sync_enabled') is True and b.get('app_running') is False)
        checks['icloud']['icloud.fixture_configuration_created'] = cloud.is_file()
        remote = json.loads(cloud.read_text())
        remote['values']['file.0.hotkey'] = {'key_code': 40, 'modifiers': ['alt']}
        write(cloud, remote)

        def cycle():
            call('icloud', 'disable_for_receive', ['config', 'sync', 'off', '--yes'], lambda b: b.get('sync_enabled') is False)
            return call('icloud', 'receive_remote_pass', ['config', 'sync', 'on', '--yes'], lambda b: b.get('sync_enabled') is True)

        cycle()
        call('icloud', 'remote_change_fresh_readback', ['config', 'get'],
             lambda b: b.get('hotkey', {}).get('key') == 'alt+k', isolated=True)
        call('shortcuts', 'restore_before_conflict', ['config', 'set', 'hotkey', 'alt+j'], lambda b: b.get('ok') is True, isolated=True)
        remote = json.loads(cloud.read_text()); remote['values']['file.0.hotkey'] = {'key_code': 4, 'modifiers': ['alt']}
        write(cloud, remote)
        cycle()
        call('icloud', 'conflict_keeps_changed_local', ['config', 'get'],
             lambda b: b.get('hotkey', {}).get('key') == 'alt+j', isolated=True)
        checks['icloud']['icloud.conflict_pushed_to_fixture'] = json.loads(cloud.read_text())['values']['file.0.hotkey']['key_code'] == 38
        good_cloud = cloud.read_bytes()
        call('icloud', 'off_before_bad_remote', ['config', 'sync', 'off', '--yes'], lambda b: b.get('sync_enabled') is False)
        cloud.write_text('{broken')
        local_before = settings_path.read_bytes()
        call('icloud', 'bad_remote_refused', ['config', 'sync', 'on', '--yes'],
             lambda b: b.get('ok') is False and b.get('error', {}).get('code') == 'sync_incomplete', 1)
        checks['icloud']['icloud.bad_remote_preserves_local'] = settings_path.read_bytes() == local_before
        call('icloud', 'off_preserves_data', ['config', 'sync', 'off', '--yes'], lambda b: b.get('sync_enabled') is False)
        checks['icloud']['icloud.disable_keeps_local_and_cloud'] = settings_path.read_bytes() == local_before and cloud.read_text() == '{broken'
        blocked_cloud = run / 'unavailable-cloud'; blocked_cloud.write_text('not a directory')
        call('icloud', 'unavailable_falls_back', ['config', 'sync', 'on', '--yes'],
             lambda b: b.get('ok') is False and b.get('error', {}).get('code') == 'sync_incomplete', 1,
             override={'APP_LIFECYCLE_CLOUD_DIR': str(blocked_cloud)})
        call('icloud', 'local_usable_offline', ['config', 'get'], lambda b: b.get('hotkey', {}).get('key') == 'alt+j', isolated=True)
        call('icloud', 'off_after_unavailable', ['config', 'sync', 'off', '--yes'], lambda b: b.get('sync_enabled') is False)
        cloud.write_bytes(good_cloud)
        call('icloud', 'recovery_after_valid_remote', ['config', 'sync', 'on', '--yes'], lambda b: b.get('sync_enabled') is True)
        call('icloud', 'finish_disabled', ['config', 'sync', 'off', '--yes'], lambda b: b.get('sync_enabled') is False)

        call('updates', 'save_options', ['update', 'options', '--auto-check', 'on', '--interval', '6', '--yes'],
             lambda b: b.get('options', {}).get('automaticCheck') is True and b.get('options', {}).get('intervalHours') == 6)
        options = call('updates', 'fresh_options_readback', ['update', 'options'],
                       lambda b: b.get('options', {}).get('automaticCheck') is True and b.get('options', {}).get('intervalHours') == 6)
        call('updates', 'invalid_interval_refused', ['update', 'options', '--interval', '0', '--yes'],
             lambda b: b.get('error', {}).get('code') == 'usage', 2)
        call('updates', 'invalid_options_preserve_previous', ['update', 'options'], lambda b: b.get('options') == options.get('options'))
        call('updates', 'disable_auto_check', ['update', 'options', '--auto-check', 'off', '--yes'],
             lambda b: b.get('options', {}).get('automaticCheck') is False)
        # There is no injectable test update source in the installed product's public CLI. An isolation refusal
        # is evidence of a safe boundary, not evidence that the updater checked a fixture or recovered from it.
        call('updates', 'isolated_check_refused_safely', ['update', 'check'],
             lambda b: b.get('ok') is False and '隔离' in str(b.get('error')), 1, True)
        checks['updates']['updates.test_source_checked'] = False
        checks['updates']['updates.bad_feed_recovery'] = False
        checks['updates']['updates.upgrade_preserves_data'] = False
        missing['updates'].append('Installed CLI fixes the update source to GitHub and rejects checks in product isolation; no safe test-feed/failed-upgrade entry is exposed. Source work is outside this task.')
    except Exception as caught:
        error = str(caught)
        for feature in FEATURES:
            checks[feature][feature + '.suite_completed'] = False
            missing[feature].append(error)
    finally:
        if clone.is_dir():
            subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-u', str(clone)], capture_output=True, timeout=10)
        # Only the unique disposable identity, never the installed product domain.
        if env is not None:
            subprocess.run(['defaults', 'delete', identity], env=env, capture_output=True, timeout=10)

    after = production_snapshot()
    # Canonical policy scenarios are derived from concrete observations, never from registration/source presence.
    scenarios = {
        'settings': {
            'interaction': ['settings_record_applies', 'settings_reflect_state', 'offscreen_installed_self_test'],
            'persisted_readback': ['save', 'fresh_process_readback', 'import'],
            'error_preserves_data': ['bad_value_refused', 'invalid_input_preserves_file', 'config_wrong_field_import_is_atomic']},
        'shortcuts': {
            'action_path': ['enter_dispatch', 'esc_closes_panel_only', 'hotkey_set_registers'],
            'disable_restore': ['hotkey_clear', 'builtin_switch_registers', 'clear_fresh_readback', 'restore_fresh_readback'],
            'conflict_or_reserved_keys': ['refused_hotkey_keeps_previous', 'system_hotkey_refused', 'failed_builtin_switch_rolls_back']},
        'icloud': {
            'push_pull': ['enable_and_push', 'fixture_configuration_created', 'remote_change_fresh_readback'],
            'unavailable_local_fallback': ['unavailable_falls_back', 'local_usable_offline'],
            'conflict_or_corrupt_recovery': ['conflict_keeps_changed_local', 'conflict_pushed_to_fixture', 'bad_remote_refused',
                                           'bad_remote_preserves_local', 'recovery_after_valid_remote'],
            'disable_preserves_data': ['off_preserves_data', 'disable_keeps_local_and_cloud']},
        'updates': {
            'check_result': ['test_source_checked'],
            'failure_recovery': ['bad_feed_recovery'],
            'options_or_store_entry': ['save_options', 'fresh_options_readback', 'invalid_options_preserve_previous'],
            'data_preservation': ['upgrade_preserves_data']}}
    for feature, groups in scenarios.items():
        for scenario, observations in groups.items():
            checks[feature][feature + '.' + scenario] = all(
                checks[feature].get(feature + '.' + name) is True for name in observations)
        for required in spec['features'][feature].get('required_checks', []):
            if required not in checks[feature]:
                checks[feature][required] = False
                missing[feature].append('No actual acceptance path for newly required scenario: ' + required)
    for feature in FEATURES:
        checks[feature][feature + '.production_unchanged'] = before == after
        checks[feature][feature + '.binding_still_current'] = (sha(APP / artifact['executable']) == installed_sha
            and sha(receipt_path) == binding['receipt_sha256']
            and input_files(receipt['source']['input_globs']) == set(source_files)
            and all((ROOT / name).is_file() and sha(ROOT / name) == checksum for name, checksum in source_files.items()))
    upstream = {'path': str((ui_dir / 'self-test.json').relative_to(ROOT)),
                'sha256': sha(ui_dir / 'self-test.json')} if (ui_dir / 'self-test.json').is_file() else None
    features = {}
    scope = ('Installed download edition, copied without recompilation and re-signed only for a disposable identity; '
             'real offscreen views/recording callbacks and isolated CLI persistence. Shortcut delivery uses no synthetic input '
             'and no real global registration. iCloud is the shared production sync engine using a private local cloud fixture; '
             'Apple server transfer between devices is not tested. Update options are real; test-feed and upgrade recovery are unavailable.')
    for feature in FEATURES:
        raw_path = run / (feature + '.json')
        raw = {'schema_version': 1, 'app_id': app_id, 'spec_digest': spec['digest'],
               'checked_at': time.time(), 'feature': feature, 'checks': checks[feature],
               'binding': binding, 'scope': scope, 'cases': [case for case in cases if case['feature'] == feature],
               'upstream_self_test': upstream, 'missing': missing[feature], 'error': error}
        write(raw_path, raw)
        features[feature] = {'result': 'passed' if all(value is True for value in checks[feature].values()) else 'failed',
                             'method': 'ui_automation' if feature == 'settings' else 'real_product',
                             'evidence': str(raw_path.relative_to(ROOT)), 'evidence_sha256': sha(raw_path),
                             'checks': list(checks[feature]), 'missing': missing[feature]}
    passed = all(feature['result'] == 'passed' for feature in features.values())
    counts = {feature: f"{sum(value is True for value in checks[feature].values())}/{len(checks[feature])}" for feature in FEATURES}
    detail = {'schema_version': 1, 'app_id': app_id, 'spec_digest': spec['digest'], 'features': features,
              'summary': f"当前装机 {binding['version']} ({binding['build']})：" + '；'.join(f'{feature} {counts[feature]}' for feature in FEATURES),
              'scope': scope, 'run': str(run.relative_to(ROOT))}
    write(out / 'product_basics.detail.json', detail)
    print(detail['summary'], flush=True)
    if error:
        print(error, flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
