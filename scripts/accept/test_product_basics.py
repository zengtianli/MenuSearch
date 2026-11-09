"""Evidence stays in the source repository when Chapter executes an APFS clone."""
import importlib.util
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location('product_basics', Path(__file__).with_name('product_basics.py'))
basics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(basics)


@pytest.fixture
def contract(tmp_path, monkeypatch):
    repo = tmp_path / 'repo'
    clone = tmp_path / 'clone'
    repo.mkdir()
    clone.mkdir()
    monkeypatch.setattr(basics, 'ROOT', clone)
    monkeypatch.setenv('SOP_APP_ID', 'menu-search')
    monkeypatch.setenv('SOP_REPO', str(clone))
    monkeypatch.setenv('SOP_SOURCE_REPO', str(repo))
    monkeypatch.setenv('SOP_OUT_DIR', str(repo / 'perf/acceptance'))
    return repo, clone


def test_clone_writes_evidence_relative_to_original_repo(contract):
    repo, _ = contract
    root, out = basics.evidence_location({'app_id': 'menu-search'})
    assert root == repo
    assert str((out / 'run/settings.json').relative_to(root)) == 'perf/acceptance/run/settings.json'


def test_in_place_run_without_source_override(contract, monkeypatch):
    _, clone = contract
    monkeypatch.delenv('SOP_SOURCE_REPO')
    monkeypatch.setenv('SOP_OUT_DIR', str(clone / 'perf/acceptance'))
    assert basics.evidence_location({'app_id': 'menu-search'}) == (clone, clone / 'perf/acceptance')


@pytest.mark.parametrize('field,value', [
    ('SOP_APP_ID', 'another-app'),
    ('SOP_REPO', '/unrelated-worktree'),
    ('SOP_OUT_DIR', '/unrelated-output'),
])
def test_rejects_mismatched_contract(contract, monkeypatch, field, value):
    monkeypatch.setenv(field, value)
    with pytest.raises(ValueError):
        basics.evidence_location({'app_id': 'menu-search'})


def test_rejects_output_symlink_escape(contract):
    repo, clone = contract
    (repo / 'perf').mkdir()
    (repo / 'perf/acceptance').symlink_to(clone, target_is_directory=True)
    with pytest.raises(ValueError):
        basics.evidence_location({'app_id': 'menu-search'})


def test_candidate_in_symlinked_build_directory(contract):
    _, clone = contract
    build = clone / 'build.noindex'
    (build / 'accept').mkdir(parents=True)
    (clone / 'build').symlink_to(build, target_is_directory=True)
    basics.validate_candidate_paths(build / 'quick/MenuSearch.app', build / 'accept/receipt.json')


@pytest.mark.parametrize('app,receipt', [
    ('outside/MenuSearch.app', 'build/accept/receipt.json'),
    ('build/quick/MenuSearch.app', 'outside/receipt.json'),
])
def test_rejects_candidate_outside_build(contract, app, receipt):
    _, clone = contract
    with pytest.raises(ValueError):
        basics.validate_candidate_paths(clone / app, clone / receipt)
