"""Invariant tests for manual and script element sandbox runtimes.

In FSDK 26.08, runtime-minimal.bst no longer ships /bin/sh. Elements of
kind: manual or kind: script execute commands within their build-time
sandbox and must depend on base/base-stack.bst in build-depends to guarantee
a working shell environment.
"""

from __future__ import annotations

from pathlib import Path
import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
ELEMENTS_DIR = REPO_ROOT / "elements"


def test_manual_and_script_elements_depend_on_base_stack():
    """Ensure all manual/script elements have base/base-stack.bst in build-depends."""
    for bst_path in ELEMENTS_DIR.rglob("*.bst"):
        # Skip external junction declarations
        if bst_path.name in ("freedesktop-sdk.bst", "gnome-build-meta.bst"):
            continue

        content = bst_path.read_text(encoding="utf-8")
        # Quick check for kind
        if "kind: manual" not in content and "kind: script" not in content:
            continue

        data = yaml.safe_load(content)
        if not isinstance(data, dict):
            continue

        kind = data.get("kind")
        if kind in ("manual", "script"):
            build_depends = data.get("build-depends", [])
            dep_names = []
            for dep in build_depends:
                if isinstance(dep, str):
                    dep_names.append(dep)
                elif isinstance(dep, dict) and "filename" in dep:
                    dep_names.append(dep["filename"])

            assert "base/base-stack.bst" in dep_names, (
                f"{bst_path.relative_to(REPO_ROOT)} is kind: {kind} but does not include "
                f"base/base-stack.bst in build-depends"
            )


def test_compose_elements_declare_integration_explicitly():
    """Compose elements must say whether integration commands run.

    Shell-less compositions must set integrate: False (FSDK 26.08
    runtime-minimal has no /bin/sh). Compositions that ship a shell and need
    integration (the ld.so cache, hwdb) opt in with integrate: True.
    """
    for bst_path in ELEMENTS_DIR.rglob("*.bst"):
        if bst_path.name in ("freedesktop-sdk.bst", "gnome-build-meta.bst"):
            continue

        content = bst_path.read_text(encoding="utf-8")
        if "kind: compose" not in content:
            continue

        data = yaml.safe_load(content)
        if not isinstance(data, dict) or data.get("kind") != "compose":
            continue

        config = data.get("config", {})
        assert config.get("integrate") in (True, False), (
            f"{bst_path.relative_to(REPO_ROOT)} is kind: compose but does not set "
            f"'integrate:' explicitly in config"
        )


def test_os_stack_uses_fsdk_base():
    """The OS payload is pure freedesktop-sdk: os-base.bst, no Flatcar imports."""
    os_stack = ELEMENTS_DIR / "bluefin-server" / "os-stack.bst"
    depends = yaml.safe_load(os_stack.read_text(encoding="utf-8")).get("depends", [])
    os_base = ELEMENTS_DIR / "bluefin-server" / "os-base.bst"
    base_depends = yaml.safe_load(os_base.read_text(encoding="utf-8")).get("depends", [])

    assert "bluefin-server/os-base.bst" in depends
    assert "freedesktop-sdk.bst:components/systemd.bst" in base_depends
    assert "bluefin-server/kernel-modules.bst" in base_depends
    for dep in depends + base_depends:
        assert not dep.startswith("flatcar/"), (
            f"OS payload must not import Flatcar binaries ({dep})"
        )


def test_installer_stack_includes_uutils_and_dbus():
    """Installer stack must include uutils-coreutils, dbus, and dbus-broker."""
    installer_stack = ELEMENTS_DIR / "installer" / "installer-stack.bst"
    data = yaml.safe_load(installer_stack.read_text(encoding="utf-8"))
    depends = data.get("depends", [])

    assert "bluefin-server/uutils-coreutils.bst" in depends, (
        "installer-stack.bst must include bluefin-server/uutils-coreutils.bst"
    )
    assert "freedesktop-sdk.bst:components/dbus.bst" in depends, (
        "installer-stack.bst must include freedesktop-sdk.bst:components/dbus.bst for dbus.socket"
    )
    assert "freedesktop-sdk.bst:components/dbus-broker.bst" in depends, (
        "installer-stack.bst must include freedesktop-sdk.bst:components/dbus-broker.bst"
    )


def test_os_countme_depends_on_curl_and_jq():
    """os-countme.bst must ship curl and jq through the freedesktop-sdk junction.

    Regression test for projectbluefin/server#96: the curl dependency was
    inferred rather than verified, so a wrong path would fail to resolve and
    the minimal image (which ships neither curl nor jq) would not build.
    Confirmed that the pinned freedesktop-sdk ref (freedesktop-sdk-26.08.0,
    elements/freedesktop-sdk.bst) ships both elements/components/curl.bst and
    elements/components/jq.bst, so the dependency must stay on this exact path.
    """
    countme = ELEMENTS_DIR / "bluefin-server" / "os-countme.bst"
    data = yaml.safe_load(countme.read_text(encoding="utf-8"))
    depends = data.get("depends", [])

    assert "freedesktop-sdk.bst:components/curl.bst" in depends, (
        "os-countme.bst must include freedesktop-sdk.bst:components/curl.bst "
        "(projectbluefin/server#96)"
    )
    assert "freedesktop-sdk.bst:components/jq.bst" in depends, (
        "os-countme.bst must include freedesktop-sdk.bst:components/jq.bst "
        "(projectbluefin/server#96)"
    )


def test_installer_linker_paths_split_host_and_target():
    """Target-root ld.so.conf write and read must resolve to the same file.

    projectbluefin/server#132 (hanthor review): `ldconfig -r /target-root` chroots
    into /target-root, so the `-f /tmp/ld.so.conf` path is resolved *post-chroot* to
    /target-root/tmp/ld.so.conf. The conf is therefore written to /target-root/tmp/
    and read back via `-f /tmp/ld.so.conf`; the two must agree, not live on different
    roots. The target cache indexes Flatcar's /usr/lib64 (the FSDK libs ship there,
    not the Debian multiarch path).
    """
    installer = ELEMENTS_DIR / "oci" / "bluefin-server-installer.bst"
    text = installer.read_text(encoding="utf-8")

    # Target linker search path (what the target-root cache indexes).
    assert "/usr/lib64\\n/usr/lib64/systemd\\n" in text, (
        "installer must index Flatcar /usr/lib64 for the target-root cache "
        "(projectbluefin/server#132)"
    )
    # Conf written to /target-root/tmp and read via `-f /tmp/ld.so.conf` under
    # `-r /target-root` (which resolves to /target-root/tmp/ld.so.conf post-chroot).
    assert "> /target-root/tmp/ld.so.conf" in text, (
        "installer must write the target ld.so.conf to /target-root/tmp, matching "
        "the `ldconfig -r /target-root -f /tmp/ld.so.conf` read "
        "(projectbluefin/server#132)"
    )
    assert "ldconfig -r /target-root -f /tmp/ld.so.conf" in text, (
        "installer must read the target conf from /tmp with `-r /target-root "
        "(projectbluefin/server#132)"
    )
    # Cleanup removes the same post-chroot path it wrote.
    assert "rm -f /target-root/tmp/ld.so.conf" in text, (
        "installer must clean up /target-root/tmp/ld.so.conf "
        "(projectbluefin/server#132)"
    )




