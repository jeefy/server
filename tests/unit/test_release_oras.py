"""The release job's ORAS CLI matches the one ``just publish-oci`` runs.

Only pushes to main run the release job, so a setup-oras pin the action cannot
resolve first fails after a release was already created. setup-oras resolves a
``version`` input against its bundled releases.json, which lags ORAS releases;
the workflow therefore pins the official tarball by URL and sha256.
"""

import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "build.yml"
JUSTFILE = ROOT / "Justfile"


def _setup_oras_inputs():
    jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
    steps = [s for s in jobs["release"]["steps"] if "setup-oras" in s.get("uses", "")]
    assert len(steps) == 1, "the release job sets up oras exactly once"
    return steps[0].get("with") or {}


def test_setup_oras_pins_the_release_tarball_by_checksum():
    inputs = _setup_oras_inputs()
    assert "version" not in inputs, "setup-oras rejects versions missing from its releases.json"
    assert re.fullmatch(r"[0-9a-f]{64}", inputs.get("checksum", ""))
    assert re.fullmatch(
        r"https://github\.com/oras-project/oras/releases/download/"
        r"v(\d+\.\d+\.\d+)/oras_\1_linux_amd64\.tar\.gz",
        inputs.get("url", ""),
    )


def test_release_oras_matches_the_justfile_oras_image():
    url = _setup_oras_inputs()["url"]
    ci_version = re.search(r"/download/v([^/]+)/", url).group(1)
    image = re.search(r'oras_image := env\("ORAS_IMAGE", "([^"]+)"\)', JUSTFILE.read_text(encoding="utf-8"))
    assert image, "Justfile no longer defines oras_image"
    assert image.group(1).endswith(f":v{ci_version}"), (
        f"CI installs ORAS {ci_version} but just publish-oci runs {image.group(1)}"
    )
