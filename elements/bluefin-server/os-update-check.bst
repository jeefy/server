kind: import
description: |
  /usr/libexec/bluefin-diskless-update-check, run by
  bluefin-diskless-update-check.timer (files/os/systemd/system, enabled by
  80-bluefin-updates.preset) on diskless boots only: fetches the signed
  SHA256SUMS from the directory the node booted from, and when it lists a
  newer bluefin-server_<ver>.raw than the running IMAGE_VERSION, touches
  /run/reboot-required for kured or the operator. It never reboots.
  Runtime tools: bash, coreutils, curl, gpgv, systemd-analyze (os-base.bst)
  and bluefin-boot-origin (boot-origin.bst).

sources:
- kind: local
  path: files/os/update-check
