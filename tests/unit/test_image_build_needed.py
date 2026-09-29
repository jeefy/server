"""Unit coverage for .github/scripts/image-build-needed.py.

The build workflow skips the ~2 h image build and the boot test for pull
requests the script classifies as not touching the image. A wrong `false`
merges an untested image change, so the invariant guarded here is that every
tracked file under a build input root, and the build workflow itself, always
builds.
"""

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".github" / "scripts" / "image-build-needed.py"

_spec = importlib.util.spec_from_file_location("image_build_needed", SCRIPT)
image_build_needed = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(image_build_needed)


def tracked_files():
    out = subprocess.run(
        ["git", "ls-files"], cwd=ROOT, check=True, capture_output=True, text=True
    ).stdout
    return [line for line in out.splitlines() if line]


def test_every_build_input_builds():
    inputs = [
        p
        for p in tracked_files()
        if p.startswith(image_build_needed.BUILD_PREFIXES)
        or p in {"project.conf", "Justfile", ".github/workflows/build.yml"}
        or p.startswith(".github/scripts/check-")
    ]
    assert inputs, "git ls-files returned no build inputs"
    skipped = [p for p in inputs if not image_build_needed.needs_build(p)]
    assert skipped == []


def test_the_classifier_itself_builds():
    assert image_build_needed.needs_build(".github/scripts/image-build-needed.py")


@pytest.mark.parametrize(
    "path",
    [
        "docs/skills/ci-tooling.md",
        "README.md",
        ".github/copilot-instructions.md",
        "tests/unit/test_repart_layout.py",
        "tests/unit/os-justfile_test.bats",
        ".github/scripts/docs-checks.py",
        ".github/workflows/unit-tests.yml",
    ],
)
def test_docs_and_unit_test_changes_skip(path):
    assert not image_build_needed.needs_build(path)


@pytest.mark.parametrize(
    "path",
    [
        "files/os/README.md",
        "elements/notes.md",
        "tests/fixtures/ignition/apply-marker.ign",
        "scripts/dogfood-diskless.sh",
        "renovate.json",
        "a-new-top-level-file",
    ],
)
def test_build_inputs_and_unknown_paths_build(path):
    assert image_build_needed.needs_build(path)


def test_one_build_input_among_docs_builds():
    assert image_build_needed.image_build_needed(["docs/a.md", "elements/x.bst"])


def test_empty_or_truncated_lists_build():
    assert image_build_needed.image_build_needed([])
    many = ["docs/x.md"] * image_build_needed.API_FILE_LIMIT
    assert image_build_needed.image_build_needed(many)


def test_cli_reads_stdin():
    def run(text):
        return subprocess.run(
            [sys.executable, str(SCRIPT)], input=text, capture_output=True, text=True, check=True
        ).stdout.strip()

    assert run("docs/skills/index.md\nREADME.md\n") == "false"
    assert run("docs/skills/index.md\nfiles/os/x\n") == "true"
