"""Installing onto a disk that is not empty (#359).

systemd-repart v261 erases the disk for sysinstall's --erase=yes but keeps the
kernel's partition devices of what the disk held, so adding the new ESP's
partition device (BLKPG) and rereading the new partition table failed with
EBUSY on any disk with partitions. The USB installer forgets those partition
devices (udev rule) before sysinstall starts.
"""

from __future__ import annotations

import re
from pathlib import Path

from _systemd import SystemdFile

ROOT = Path(__file__).resolve().parents[2]
RULES = ROOT / "files" / "os" / "udev" / "rules.d" / "90-bluefin-installer-forget-partitions.rules"
ELEMENT = ROOT / "elements" / "bluefin-server" / "os-udev-rules.bst"
OS_STACK = ROOT / "elements" / "bluefin-server" / "os-stack.bst"
DROPIN = ROOT / "files" / "os" / "systemd" / "system" / "systemd-sysinstall.service.d" / "10-bluefin-installer.conf"
BOOT_ELEMENT = ROOT / "elements" / "oci" / "bluefin-server-boot.bst"


def rules() -> list[str]:
    return [line for line in RULES.read_text(encoding="utf-8").splitlines() if line and not line.startswith("#")]


def test_the_rule_only_runs_in_the_installer_boot():
    # Installed and diskless nodes may use other disks' partitions (/var on
    # disk, data disks); only the installer UKI boots system-install.target.
    text = "\n".join(rules())
    assert 'IMPORT{cmdline}="systemd.unit"' in text
    assert 'ENV{systemd.unit}!="system-install.target", GOTO="bluefin_installer_end"' in text
    assert "system-install.target" in BOOT_ELEMENT.read_text(encoding="utf-8")


def test_the_rule_only_forgets_partition_devices_and_changes_no_disk():
    runs = [line for line in rules() if "RUN" in line]
    assert runs == ['RUN+="/usr/bin/partx --delete $devnode"']
    assert 'ENV{DEVTYPE}!="partition", GOTO="bluefin_installer_end"' in rules()


def test_the_stick_keeps_its_partitions():
    # Its usr (dm-verity) and ESP (/run/bluefin/installer) are the installer.
    assert 'ENV{ID_PART_ENTRY_NAME}=="bluefin-installer*", GOTO="bluefin_installer_end"' in rules()


def test_the_new_install_keeps_its_partitions():
    # repart and sysinstall add the target's new partition devices while
    # sysinstall runs; its RuntimeDirectory= marks that.
    runtime = SystemdFile(DROPIN).value("Service", "RuntimeDirectory")
    assert runtime == "bluefin-sysinstall"
    assert f'TEST=="/run/{runtime}", GOTO="bluefin_installer_end"' in rules()
    # Every guard comes before the action.
    lines = rules()
    run = next(i for i, line in enumerate(lines) if line.startswith("RUN"))
    assert all("GOTO" not in line for line in lines[run:])


def test_the_rule_runs_after_blkid_labelled_the_partition():
    # ID_PART_ENTRY_NAME comes from 60-persistent-storage.rules.
    assert int(re.match(r"(\d+)-", RULES.name).group(1)) > 60


def test_the_rule_ships_in_the_os_image():
    element = ELEMENT.read_text(encoding="utf-8")
    assert "path: files/os/udev/rules.d" in element
    assert "target: /usr/lib/udev/rules.d" in element
    assert "- bluefin-server/os-udev-rules.bst" in OS_STACK.read_text(encoding="utf-8")
