"""Regression checks for resource deferral and the installed-artifact acceptance contract."""
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def lane(tmp_path, monkeypatch):
    trace = tmp_path / 'trace'
    module = tmp_path / 'sim_lane.py'
    module.write_text('''
import os
from pathlib import Path
def record(event):
    with Path(os.environ['TRACE']).open('a') as stream: stream.write(event + '\\n')
class Busy(Exception): pass
class BuildSlot:
    def __init__(self, label, wait): assert wait == 0
    def __enter__(self):
        record('slot')
        if os.environ.get('BUSY'): raise Busy('busy')
    def __exit__(self, *args): record('slot-released')
class Lock:
    def release(self): record('lock-released')
def lock_chain(label):
    record('lock')
    return [Lock()]
def max_load_default(): return 10
def acquire(locks, udid, lock_wait, load_wait, max_load):
    assert udid is None and lock_wait == load_wait == 0
    record('quiet')
    if os.environ.get('BUSY'): raise Busy('busy')
''')
    monkeypatch.setenv('SIM_LANE_SCRIPT', str(module))
    monkeypatch.setenv('TRACE', str(trace))
    monkeypatch.delenv('BUSY', raising=False)
    # Exercise the actual shell entry's Python scheduling body, without taking real shared resources.
    body = (ROOT / 'build.sh').read_text().split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
    command = "import os; from pathlib import Path; p=Path(os.environ['TRACE']); p.write_text(p.read_text()+'command\\n')"

    def run(phase, exit_code=0):
        trace.unlink(missing_ok=True)
        result = subprocess.run([sys.executable, '-c', body, phase, sys.executable, '-c',
                                 command + f'; raise SystemExit({exit_code})'], capture_output=True, text=True)
        events = trace.read_text().splitlines() if trace.exists() else []
        return result.returncode, events
    return run


def test_compilation_uses_parallel_slot_only(lane):
    assert lane('compile') == (0, ['slot', 'command', 'slot-released'])


def test_timing_uses_quiet_gate_and_releases(lane):
    assert lane('measure') == (0, ['lock', 'quiet', 'command', 'lock-released'])


@pytest.mark.parametrize('phase', ['compile', 'measure'])
def test_busy_defers_without_running_command(lane, monkeypatch, phase):
    monkeypatch.setenv('BUSY', '1')
    code, events = lane(phase)
    assert code == 75 and 'command' not in events
    if phase == 'measure':
        assert events[-1] == 'lock-released'


@pytest.mark.parametrize('phase', ['compile', 'measure'])
def test_business_failure_stays_failure(lane, phase):
    code, events = lane(phase, 1)
    assert code == 1 and 'command' in events


@pytest.mark.parametrize('exit_code', [75, 1])
def test_acceptance_preserves_build_deferral(tmp_path, monkeypatch, exit_code):
    accept = load('menu_accept', ROOT / 'scripts/accept/run.py')
    monkeypatch.setattr(accept, 'ROOT', tmp_path)
    monkeypatch.setattr(accept, 'VENDOR', tmp_path / 'missing')
    monkeypatch.setattr(accept, 'source_hash', lambda: 'fixed')
    monkeypatch.setattr(accept.subprocess, 'run', lambda *a, **k: subprocess.CompletedProcess(a, exit_code, '', ''))
    with pytest.raises(SystemExit) as caught:
        accept.build()
    assert caught.value.code == (75 if exit_code == 75 else 'build failed')


def test_busy_acceptance_cache_does_not_wait(tmp_path, monkeypatch):
    import fcntl
    accept = load('menu_accept', ROOT / 'scripts/accept/run.py')
    monkeypatch.setattr(accept, 'ROOT', tmp_path)
    (tmp_path / 'build/accept').mkdir(parents=True)
    with (tmp_path / 'build/accept/.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with pytest.raises(SystemExit) as caught:
            accept.build()
    assert caught.value.code == 75


@pytest.fixture
def basics():
    return load('menu_basics', ROOT / 'scripts/accept/product_basics.py')


def test_chapter_current_verdict_is_required(basics, monkeypatch):
    monkeypatch.setenv('SOP_CODE_BINDING_SHA256', 'a' * 64)
    monkeypatch.setenv('SOP_BUILD_CURRENT', '1')
    assert basics.code_binding()['current'] is True
    monkeypatch.setenv('SOP_BUILD_CURRENT', '0')
    assert basics.code_binding()['current'] is False
    monkeypatch.setenv('SOP_BUILD_CURRENT', '1')
    monkeypatch.delenv('SOP_CODE_BINDING_SHA256')
    assert basics.code_binding()['current'] is False


def test_source_recheck_ignores_test_churn_but_detects_production_changes(basics, tmp_path, monkeypatch):
    monkeypatch.setattr(basics, 'ROOT', tmp_path)
    monkeypatch.setenv('SOP_CONFIG', json.dumps({'source': ['Sources/**', 'Resources/**', 'Tests/**']}))
    for name in ['Sources/main.swift', 'Resources/tuning.json', 'Tests/main.swift']:
        path = tmp_path / name
        path.parent.mkdir(exist_ok=True)
        path.write_text('original')
    before = basics.source_snapshot()
    (tmp_path / 'Tests/main.swift').write_text('new test')
    assert basics.source_snapshot() == before
    (tmp_path / 'Resources/tuning.json').write_text('production changed')
    assert basics.source_snapshot() != before


@pytest.mark.parametrize('field,value', [('CFBundleIdentifier', 'other.product'),
                                         ('CFBundleVersion', '1'), ('CFBundleShortVersionString', '0.3.0')])
def test_chapter_verdict_cannot_override_artifact_mismatch(basics, field, value):
    info = {'CFBundleIdentifier': basics.PRODUCT, 'CFBundleShortVersionString': '0.3.3', 'CFBundleVersion': '12'}
    artifact = {'bundle_id': basics.PRODUCT, 'version': '0.3.3', 'build': '12', 'sha256': 'expected'}
    assert basics.artifact_matches(info, 'expected', artifact)
    assert not basics.artifact_matches({**info, field: value}, 'expected', artifact)
    assert not basics.artifact_matches(info, 'wrong executable', artifact)


def test_failed_binding_emits_failed_fixed_evidence(basics, tmp_path, monkeypatch):
    app = tmp_path / 'MenuSearch.app'
    executable = app / 'Contents/MacOS/MenuSearch'
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b'store binary')
    info = {'CFBundleIdentifier': basics.PRODUCT, 'CFBundleShortVersionString': '0.3.0', 'CFBundleVersion': '1'}
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    receipt = tmp_path / 'receipt.json'
    receipt.write_text(json.dumps({'artifact': {'bundle_id': basics.PRODUCT, 'version': '0.3.3', 'build': '12',
                                               'executable': 'Contents/MacOS/MenuSearch', 'sha256': 'different'},
                                    'source': {}}))
    out = tmp_path / 'perf/acceptance/run'
    out.mkdir(parents=True)
    monkeypatch.setattr(basics, 'ROOT', tmp_path)
    monkeypatch.setattr(basics, 'APP', app)
    monkeypatch.setattr(basics, 'production_snapshot', lambda: {'executable_sha256': basics.sha(executable)})
    monkeypatch.setattr(basics, 'signature_valid', lambda app: True)
    monkeypatch.setattr(sys, 'argv', ['product_basics.py', '--app', str(app), '--receipt', str(receipt)])
    monkeypatch.setenv('SOP_APP_ID', 'menu-search')
    monkeypatch.setenv('SOP_OUT_DIR', str(out))
    monkeypatch.setenv('SOP_PRODUCT_BASICS_SPEC', json.dumps({'app_id': 'menu-search', 'digest': 'spec',
                                                         'features': {key: {} for key in basics.FEATURES}}))
    monkeypatch.setenv('SOP_CODE_BINDING_SHA256', 'a' * 64)
    monkeypatch.setenv('SOP_BUILD_CURRENT', '1')
    assert basics.main() == 1
    detail = json.loads((out / 'product_basics.detail.json').read_text())
    assert all(feature['result'] == 'failed' for feature in detail['features'].values())
