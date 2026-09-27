kind: script
description: |
  Signed boot chain for Bluefin Server.

  Outputs:
    bluefin-server_<ver>.efi                  UKI: FSDK kernel + systemd initrd + cmdline
                                              pinning usrhash=, signed with DB
    systemd-bootx64.efi                       systemd-boot, signed with DB
    efi-keys/{PK,KEK,db}.auth                 Secure Boot enrollment payloads
    bluefin-server-netboot_<ver>.esp.raw      ESP image (systemd-boot + UKI + keys):
                                              boots diskless from any disk or USB stick
    SHA256SUMS

  The cmdline asks the initrd to download bluefin-server_<ver>.raw from the
  UEFI HTTP boot origin. Outside HTTP boot, pass the URL as the import.pull
  system credential (SMBIOS type 11, or /loader/credentials on the ESP).

(@):
- include/arch.yml
- include/image.yml

build-depends:
- base/base-stack.bst
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- freedesktop-sdk.bst:components/cpio.bst
- freedesktop-sdk.bst:components/dosfstools.bst
- freedesktop-sdk.bst:components/findutils.bst
- freedesktop-sdk.bst:components/kmod.bst
- freedesktop-sdk.bst:components/mtools.bst
- freedesktop-sdk.bst:components/sed.bst
- freedesktop-sdk.bst:components/systemd.bst
- freedesktop-sdk.bst:components/systemd-ukify.bst
- freedesktop-sdk.bst:components/zstd.bst
- freedesktop-sdk.bst:components/_private/sbsigntools.bst
- bluefin-server/keys/boot-keys.bst
- filename: bluefin-server/keys/efi-keys.bst
  config:
    location: /efi-keys
- filename: bluefin-server/initrd/initrd-filesystem.bst
  config:
    location: /initrd
- filename: bluefin-server/kernel-modules.bst
  config:
    location: /kmods
- filename: bluefin-server/os-release.bst
  config:
    location: /osrel
- filename: oci/bluefin-server-usr.bst
  config:
    location: /usr-image

variables:
  image-name: bluefin-server_%{image-version}
  efi-arch: x64
  (?):
  - arch == "aarch64":
      efi-arch: aa64
  initrd-modules: >-
    virtio_net virtio_blk virtio_pci virtio_scsi virtio_rng
    e1000 e1000e igb igc ixgbe i40e ice r8169 tg3 bnxt_en atlantic
    mlx4_en mlx5_core r8152 cdc_ether ax88179_178a usbnet
    xhci_pci ehci_pci nvme ahci sd_mod
    loop dm_mod dm_verity erofs overlay
    tpm_crb tpm_tis efivarfs vfat nls_cp437 nls_iso8859_1
  kernel-cmdline: >-
    root=tmpfs
    mount.usr=/dev/mapper/usr mount.usrfstype=erofs mount.usrflags=ro
    rd.systemd.pull=raw,machine,verify=no,blockdev,bootorigin:rootdisk:%{image-name}.raw
    systemd.verity_usr_data=/dev/disk/by-loop-ref/rootdisk.raw-part1
    systemd.verity_usr_hash=/dev/disk/by-loop-ref/rootdisk.raw-part2
    systemd.default_device_timeout_sec=300
    lockdown=integrity
    console=tty0 console=ttyS0,115200

config:
  commands:
  - mkdir -p /tmp /var/tmp

  - |
    set -eu
    kver="$(ls /kmods/usr/lib/modules)"
    [ "$(echo "${kver}" | wc -w)" = 1 ]
    src="/kmods/usr/lib/modules/${kver}"
    dst="/initrd/usr/lib/modules/${kver}"
    rm -rf /initrd/usr/lib/modules
    mkdir -p "${dst}"
    for m in %{initrd-modules}; do
      modprobe -d /kmods/usr -S "${kver}" --show-depends "${m}" 2>/dev/null || true
    done | sed -n 's/^insmod \([^ ]*\).*/\1/p' | sort -u > /tmp/initrd-modules.txt
    while read -r path; do
      rel="${path#/kmods/usr/lib/modules/${kver}/}"
      install -Dm644 "${src}/${rel}" "${dst}/${rel}"
    done < /tmp/initrd-modules.txt
    cp "${src}"/modules.order "${src}"/modules.builtin* "${dst}/"
    depmod -b /initrd/usr "${kver}"
    echo "initrd modules: $(wc -l < /tmp/initrd-modules.txt)"
    for need in loop dm-verity erofs virtio_net; do
      grep -q "/${need}\.ko" /tmp/initrd-modules.txt || grep -q "/${need}.ko" "${src}/modules.builtin" || {
        echo "ERROR: initrd lacks ${need}" >&2; exit 1; }
    done
    install -Dm644 "${src}/vmlinuz" /tmp/vmlinuz

  - |
    set -eu
    cd /initrd
    ls -la /initrd
    for d in bin lib; do
      [ -e "${d}" ] || ln -s "usr/${d}" "${d}"
    done
    ln -sfn usr/lib/systemd/systemd init
    mkdir -p etc run sys proc dev tmp var sysroot
    ln -sfn ../usr/lib/os-release etc/initrd-release
    rm -f etc/machine-id
    systemd-sysusers --root=/initrd
    wants=usr/lib/systemd/system
    mkdir -p "${wants}/initrd.target.wants" "${wants}/network-online.target.wants"
    ln -sf ../systemd-networkd.service "${wants}/initrd.target.wants/systemd-networkd.service"
    ln -sf ../systemd-resolved.service "${wants}/initrd.target.wants/systemd-resolved.service"
    ln -sf ../imports.target "${wants}/initrd.target.wants/imports.target"
    ln -sf ../bluefin-populate-etc.service "${wants}/initrd.target.wants/bluefin-populate-etc.service"
    ln -sf ../systemd-networkd-wait-online.service "${wants}/network-online.target.wants/systemd-networkd-wait-online.service"
    for tool in systemd-importd systemd-pull; do
      [ -x "usr/lib/systemd/${tool}" ] || { echo "ERROR: initrd lacks ${tool}" >&2; exit 1; }
    done
    for tool in systemd-dissect varlinkctl systemd-tmpfiles; do
      [ -x "usr/bin/${tool}" ] || { echo "ERROR: initrd lacks ${tool}" >&2; exit 1; }
    done
    [ -x usr/lib/systemd/systemd-veritysetup ] || { echo "ERROR: initrd lacks systemd-veritysetup" >&2; exit 1; }
    rm -rf usr/share/man usr/share/doc usr/share/info usr/include usr/lib/*/pkgconfig
    find . -name '*.a' -delete
    du -sh /initrd
    find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort | cpio -o -H newc --reproducible --quiet | zstd -19 -T0 -q > /tmp/initrd.cpio.zst
    ls -lh /tmp/initrd.cpio.zst

  - |
    set -eu
    mkdir -p "%{install-root}/efi-keys"
    usrhash="$(cat /usr-image/%{image-name}.usrhash)"
    printf 'usrhash=%s %s' "${usrhash}" "%{kernel-cmdline}" > /tmp/cmdline
    cat /tmp/cmdline; echo
    ukify build \
      --linux=/tmp/vmlinuz \
      --initrd=/tmp/initrd.cpio.zst \
      --cmdline=@/tmp/cmdline \
      --os-release=@/osrel/usr/lib/os-release \
      --uname="$(ls /kmods/usr/lib/modules)" \
      --signtool=sbsign \
      --secureboot-private-key=/boot-keys/DB.key \
      --secureboot-certificate=/boot-keys/DB.crt \
      --output="%{install-root}/%{image-name}.efi"
    sbverify --cert /boot-keys/DB.crt "%{install-root}/%{image-name}.efi"
    sbsign --key /boot-keys/DB.key --cert /boot-keys/DB.crt \
      --output "%{install-root}/systemd-boot%{efi-arch}.efi" \
      "/usr/lib/systemd/boot/efi/systemd-boot%{efi-arch}.efi"
    cp /efi-keys/usr/share/bluefin-server/efi-keys/*.auth "%{install-root}/efi-keys/"

  - |
    set -eu
    esp=/tmp/esp
    arch_upper="$(echo '%{efi-arch}' | tr a-z A-Z)"
    install -Dm644 "%{install-root}/systemd-boot%{efi-arch}.efi" "${esp}/EFI/BOOT/BOOT${arch_upper}.EFI"
    install -Dm644 "%{install-root}/systemd-boot%{efi-arch}.efi" "${esp}/EFI/systemd/systemd-boot%{efi-arch}.efi"
    install -Dm644 "%{install-root}/%{image-name}.efi" "${esp}/EFI/Linux/%{image-name}.efi"
    install -Dm644 -t "${esp}/loader/keys/auto" "%{install-root}"/efi-keys/*.auth
    mkdir -p "${esp}/loader/credentials"
    printf 'timeout 3\nconsole-mode keep\nsecure-boot-enroll if-safe\n' > "${esp}/loader/loader.conf"
    mkdir -p /tmp/esp.repart.d
    printf '[Partition]\nType=esp\nFormat=vfat\nCopyFiles=/tmp/esp:/\nSizeMinBytes=256M\n' > /tmp/esp.repart.d/10-esp.conf
    systemd-repart --empty=create --size=auto --offline=yes --dry-run=no \
      --seed=6f1b0fe2-3c2a-4f2e-9f0a-b1e5e7a5e002 \
      --definitions=/tmp/esp.repart.d \
      "%{install-root}/bluefin-server-netboot_%{image-version}.esp.raw"
    cd "%{install-root}"
    sha256sum --binary *.efi *.raw > SHA256SUMS
    ls -l
