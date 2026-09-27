kind: import
description: |
  systemd-sysupdate transfer for the opt-in KubeStellar sysext
  (`systemd-sysupdate --component=kubestellar update`).

sources:
  - kind: local
    path: files/os/sysupdate.kubestellar.d

config:
  target: /usr/lib/sysupdate.kubestellar.d
