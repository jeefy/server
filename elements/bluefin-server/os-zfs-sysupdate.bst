kind: import
description: Install the ZFS component systemd-sysupdate transfer definition.

sources:
  - kind: local
    path: files/os/sysupdate.zfs.d

config:
  target: /usr/lib/sysupdate.zfs.d
