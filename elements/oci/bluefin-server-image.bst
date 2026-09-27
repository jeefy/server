kind: script
description: |
  Release artifacts for one Bluefin Server image version.

    bluefin-server_<ver>.raw               UAPI.3 DDI: usr, usr-verity, ESP (disk UKI).
                                           Diskless nodes pull it into RAM; booted
                                           diskless it is also the installer
                                           (systemd-sysinstall --definitions=
                                           /run/bluefin/boot/bluefin/repart.d copies
                                           usr and links the disk UKI).
    bluefin-server_<ver>_<uuid>.usr.raw         sysupdate source for the usr slot
    bluefin-server_<ver>_<uuid>.usr-verity.raw  sysupdate source for the verity slot
                                           (<uuid>: partition UUID derived from usrhash)
    bluefin-server-<ver>.efi               disk UKI (sysupdate source for $BOOT); the
                                           hyphen matches bootctl's "default bluefin-server-*"
    bluefin-server-netboot_<ver>.efi       diskless UKI (UEFI HTTP boot target)
    bluefin-server-netboot_<ver>.esp.raw   ESP image: signed systemd-boot + diskless
                                           UKI + key enrollment; write it to a USB
                                           stick to boot diskless without HTTP boot
    efi-keys/                              Secure Boot enrollment payloads
    SHA256SUMS

(@):
- include/image.yml

build-depends:
- base/base-stack.bst
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- freedesktop-sdk.bst:components/dosfstools.bst
- freedesktop-sdk.bst:components/mtools.bst
- freedesktop-sdk.bst:components/systemd.bst
- filename: oci/bluefin-server-usr.bst
  config:
    location: /usr-image
- filename: oci/bluefin-server-boot.bst
  config:
    location: /boot-out
- filename: bluefin-server/os-sd-boot-signed.bst
  config:
    location: /sd-boot

variables:
  image-name: bluefin-server_%{image-version}
  netboot-name: bluefin-server-netboot_%{image-version}
  disk-uki: bluefin-server-%{image-version}.efi
  efi-arch: x64
  (?):
  - arch == "aarch64":
      efi-arch: aa64

config:
  commands:
  - mkdir -p /tmp /var/tmp

  - |
    set -eu
    h="$(cat /usr-image/%{image-name}.usrhash)"
    uuid() { printf '%s-%s-%s-%s-%s' "${1:0:8}" "${1:8:4}" "${1:12:4}" "${1:16:4}" "${1:20:12}"; }
    uuid "${h:0:32}" > /tmp/usr.uuid
    uuid "${h:32:32}" > /tmp/usr-verity.uuid
    out="%{install-root}"
    cp /usr-image/%{image-name}.usr.raw "${out}/bluefin-server_%{image-version}_$(cat /tmp/usr.uuid).usr.raw"
    cp /usr-image/%{image-name}.usr-verity.raw "${out}/bluefin-server_%{image-version}_$(cat /tmp/usr-verity.uuid).usr-verity.raw"
    cp /boot-out/%{disk-uki} /boot-out/%{netboot-name}.efi "${out}/"
    cp -r /boot-out/efi-keys "${out}/"

  - |
    set -eu
    esp=/tmp/ddi-esp
    install -Dm644 /boot-out/%{disk-uki} "${esp}/EFI/Linux/%{disk-uki}"
    install -Dm644 -t "${esp}/bluefin/repart.d" /boot-out/repart.d/*.conf
    d=/tmp/ddi.repart.d
    mkdir -p "${d}"
    printf '[Partition]\nType=usr\nLabel=bluefin_usr_%{image-version}\nUUID=%s\nCopyBlocks=/usr-image/%{image-name}.usr.raw\n' "$(cat /tmp/usr.uuid)" > "${d}/10-usr.conf"
    printf '[Partition]\nType=usr-verity\nLabel=bluefin_usr_verity_%{image-version}\nUUID=%s\nCopyBlocks=/usr-image/%{image-name}.usr-verity.raw\n' "$(cat /tmp/usr-verity.uuid)" > "${d}/20-usr-verity.conf"
    printf '[Partition]\nType=esp\nFormat=vfat\nCopyFiles=%s:/\nSizeMinBytes=128M\nSizeMaxBytes=128M\n' "${esp}" > "${d}/30-esp.conf"
    systemd-repart --empty=create --size=auto --offline=yes --dry-run=no \
      --seed=6f1b0fe2-3c2a-4f2e-9f0a-b1e5e7a5e003 \
      --definitions="${d}" "%{install-root}/%{image-name}.raw"

  - |
    set -eu
    esp=/tmp/netboot-esp
    sdboot=/sd-boot/usr/lib/systemd/boot/efi/systemd-boot%{efi-arch}.efi.signed
    arch_upper="$(echo '%{efi-arch}' | tr a-z A-Z)"
    install -Dm644 "${sdboot}" "${esp}/EFI/BOOT/BOOT${arch_upper}.EFI"
    install -Dm644 "${sdboot}" "${esp}/EFI/systemd/systemd-boot%{efi-arch}.efi"
    install -Dm644 /boot-out/%{netboot-name}.efi "${esp}/EFI/Linux/%{netboot-name}.efi"
    install -Dm644 -t "${esp}/loader/keys/auto" /boot-out/efi-keys/*.auth
    mkdir -p "${esp}/loader/credentials"
    printf 'timeout 3\nconsole-mode keep\nsecure-boot-enroll if-safe\n' > "${esp}/loader/loader.conf"
    d=/tmp/netboot.repart.d
    mkdir -p "${d}"
    printf '[Partition]\nType=esp\nFormat=vfat\nCopyFiles=%s:/\nSizeMinBytes=160M\n' "${esp}" > "${d}/10-esp.conf"
    systemd-repart --empty=create --size=auto --offline=yes --dry-run=no \
      --seed=6f1b0fe2-3c2a-4f2e-9f0a-b1e5e7a5e002 \
      --definitions="${d}" "%{install-root}/%{netboot-name}.esp.raw"

  - |
    set -eu
    cd "%{install-root}"
    sha256sum --binary *.raw *.efi > SHA256SUMS
    cat SHA256SUMS
