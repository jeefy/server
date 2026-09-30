"""The BuildStream cache upload only ever runs on pushes to main, after the build.

The `bst-cache` environment's credentials may reach only the two upload steps
of the `build` job, and only when the event is a push to main; the upload runs
after every build and export step, and an always() step removes the files.
The allow-list itself is covered by test_cache_push.py.
"""

from __future__ import annotations

import json
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "build.yml"
PUSH_SCRIPT = ROOT / "scripts" / "bst-cache-push.sh"

JOBS = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
BUILD = JOBS["build"]
STEPS = BUILD["steps"]
PUSH_TO_MAIN = "github.event_name == 'push' && github.ref == 'refs/heads/main'"


def step(name_part: str) -> dict:
    (match,) = [s for s in STEPS if name_part in s.get("name", "")]
    return match


def index(s: dict) -> int:
    return STEPS.index(s)


def test_environment_is_attached_only_to_pushes_to_main():
    assert BUILD["environment"] == f"${{{{ ({PUSH_TO_MAIN}) && 'bst-cache' || '' }}}}"
    assert [name for name, job in JOBS.items() if "environment" in job] == ["build"]


def test_credentials_reach_only_the_check_and_upload_steps():
    holders = [s["name"] for s in STEPS if "CASD_CLIENT" in json.dumps(s)]
    assert holders == ["Check BuildStream cache credentials", "Upload key-free artifacts to the BuildStream cache"]
    for s in (step("Check BuildStream cache"), step("Upload key-free artifacts")):
        assert s["env"] == {"CASD_CLIENT_CERT": "${{ vars.CASD_CLIENT_CERT }}", "CASD_CLIENT_KEY": "${{ secrets.CASD_CLIENT_KEY }}"}
    for name, job in JOBS.items():
        if name != "build":
            assert "CASD_CLIENT" not in json.dumps(job)


def test_upload_is_gated_on_main_pushes_and_credentials():
    check = step("Check BuildStream cache")
    assert check["if"] == PUSH_TO_MAIN
    assert "skipping cache upload: no credentials" in check["run"]
    upload = step("Upload key-free artifacts")
    assert upload["if"] == f"{PUSH_TO_MAIN} && steps.{check['id']}.outputs.present == 'true'"


def test_upload_failure_only_warns():
    run = step("Upload key-free artifacts")["run"]
    assert "if ! bash scripts/bst-cache-push.sh; then" in run
    assert "::warning" in run


def test_upload_runs_after_every_build_and_export():
    upload = index(step("Upload key-free artifacts"))
    builders = [s for s in STEPS if any(cmd in s.get("run", "") for cmd in ("just export-image", "just validate", "just bst", "just set-version"))]
    assert builders
    for s in builders:
        assert index(s) < upload
        text = json.dumps(s)
        assert "bst-cache-push" not in text and "BST_FLAGS" not in text and "CASD" not in text


def test_cleanup_always_removes_the_credentials():
    cleanup = step("Remove BuildStream cache credentials")
    assert cleanup["if"] == "always()"
    assert cleanup["run"].strip() == "rm -rf .bst-cache-push"
    assert index(cleanup) == len(STEPS) - 1


def test_credentials_stay_out_of_uploaded_and_committed_paths():
    for s in STEPS:
        if s.get("uses", "").startswith("actions/upload-artifact@"):
            for path in s["with"]["path"].split():
                assert path.startswith(("dist/", "!dist/")), path
    ignored = (ROOT / ".gitignore").read_text().splitlines()
    assert ".bst-cache-push/" in ignored
    assert 'dir=.bst-cache-push' in PUSH_SCRIPT.read_text()
