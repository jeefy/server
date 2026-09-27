---
name: ddi-installer-build
description: Build, export, and dogfood the Bluefin Server image set (OS DDI, signed UKIs, netboot ESP) and the opt-in sysexts.
metadata:
  type: how-to
  status: stable
  last_updated: "2026-09-27"
  context7-sources:
    - /systemd/systemd
    - /apache/buildstream
---
# Image Build and Dogfood

Use this skill when you need to build the release image set, export it, boot it
in QEMU, or run the end-to-end install/update/rollback test.

## Build targets

The repo exposes the main build entrypoints through `just`. BuildStream runs
inside the FSDK `bst2` container (`just bst`); it is not installed locally.

```bash
just validate          # version invariants + resolve the shipped element graphs
just test-unit         # pytest + bats
just gen-dev-keys      # throwaway Secure Boot + module keys in files/boot-keys/
just set-version V     # set image-version in include/image.yml (<=17 chars,
                       # increasing under strverscmp)
just build-image       # build oci/bluefin-server-image.bst
just export-image      # export the release set to dist/diskless/
just build-sysext      # build oci/k0s-sysext.bst
just export-sysext     # export k0s sysext + SHA256SUMS to dist/sysext/
just build-zfs-sysext  # build oci/zfs-sysext.bst
just export-zfs-sysext # export OpenZFS sysext + SHA256SUMS to dist/sysext/
just version / just tags  # FSDK-derived point release and tag set
```

`just export-image` writes one directory per image version containing the OS
DDI, the sysupdate usr/usr-verity sources, both UKIs, the netboot ESP image,
the `efi-keys/` enrollment payloads, and `SHA256SUMS`. See
[ddi-installer.md](ddi-installer.md) for what each artifact is.

## Keys

Every image build signs: the UKIs and systemd-boot with DB, kernel modules
with the module signing certificate. `build-image` (and `validate`) depends on
`gen-dev-keys`, which generates throwaway keys in `files/boot-keys/`
(gitignored) on first run and keeps them unless `--force` is given. CI builds
on `main` unpack the `BOOT_KEYS_TARBALL` secret instead; pull requests get
throwaway keys and their images are never published.

## Dogfood: boot it in QEMU

All dogfood paths boot with Secure Boot firmware (OVMF secboot). The firmware
starts in setup mode; systemd-boot enrolls the dev keys from the ESP
(`secure-boot-enroll if-safe`) and reboots, so every later boot is verified.

```bash
just dogfood                     # interactive diskless boot of dist/diskless/
just dogfood-check               # headless: pass when the in-guest probe
                                 # reports no failed units
just dogfood-install             # diskless boot, systemd-sysinstall to a blank
                                 # disk, then boot the installed disk
just dogfood-install NEXT=<dir>  # ...then sysupdate A->B to NEXT and boot it
```

`scripts/dogfood-diskless.sh <dir> [--check]` boots the way a PXE/HTTP-booted
node would: signed systemd-boot -> signed netboot UKI -> initrd pulls
`bluefin-server_<ver>.raw` over HTTP into RAM -> dm-verity /usr, tmpfs root.
Useful environment variables:

- `DOGFOOD_IGNITION=<file>` — pass an Ignition config as the `ignition.config`
  credential (see `tests/fixtures/ignition/var-on-disk.ign`).
- `DOGFOOD_STATE_DISK=<file>` — attach a persistent second disk (`/dev/vdb`).
- `DOGFOOD_VARS=<file>` — persistent UEFI variable store (keeps enrolled keys
  across runs).
- `DOGFOOD_BOOT=disk` — boot `DOGFOOD_STATE_DISK` instead of the netboot ESP.
- `DOGFOOD_EXTRA_PROBE=<file>` — shell snippet appended to the in-guest probe.

`scripts/dogfood-install.sh <dir> [<next-dir> [<broken-dir>]]` is the full
end-to-end check: install from a diskless boot, boot the installed disk,
`systemd-sysupdate` A->B to `<next-dir>`, and with `<broken-dir>` corrupt the
updated slot and confirm boot counting rolls the node back to `<next-dir>` on
its own. CI runs the first two stages (`dogfood-diskless.sh --check`,
`dogfood-install.sh dist/diskless`) as the `boot-test` job in
`.github/workflows/build.yml` on every pull request and push to main.

## Local builds with a remote cache

If you must build locally with the cluster cache, point BuildStream at your
cache tunnel host (`<build-cache-host>`) in `~/.config/buildstream.conf`:

```yaml
projects:
  bluefin-server:
    artifacts:
      override-project-caches: false
      servers:
      - url: grpc://127.0.0.1:8980
        push: true
```

## Release automation

`.github/workflows/build.yml` runs `just validate`, exports the image set and
both sysexts, runs the QEMU boot test, and on `main` assembles
`dist/release/`, signs the combined `SHA256SUMS` with the
`SYSUPDATE_SIGNING_KEY` secret, and publishes an immutable GitHub Release
tagged `v<image-version>`. One version is published exactly once; creating an
existing tag fails rather than overwriting assets nodes may already trust.

## Common rationalizations

| Rationalization | Reality |
|---|---|
| "Skip `gen-dev-keys`, the build has defaults." | Signing needs real key material in `files/boot-keys/`; the recipe generates throwaway keys so local builds boot under Secure Boot. |
| "Test the UKI with `-kernel`/`-initrd`." | That bypasses the signed boot chain. The dogfood scripts boot the netboot ESP or installed disk through OVMF the way firmware does. |
| "Reboot loops mean the boot hung." | With Secure Boot in setup mode the first boot enrolls keys and reboots; that is expected once per fresh variable store. |
| "A failed update needs manual recovery." | Boot counting handles it: three failed boots of the new UKI and systemd-boot falls back to the previous image. `dogfood-install.sh <dir> <next> <broken>` proves it. |
| "`chmod 4755` in install-commands makes a file setuid in the image." | No. BuildStream artifacts keep one executable bit per file, so every staged file is 0644/0755. FSDK components declare their special modes as initial scripts, and `oci/bluefin-server-usr.bst` runs them (`os-initial-scripts.bst`) while assembling /sysroot; special modes must be set in the `script` element that writes the image. |

## Red flags

- A boot cmdline with a hardcoded device path.
- An initrd change that drops `loop`, `dm-verity`, `erofs`, or `virtio_net`
  (the build fails the check in `bluefin-server-boot.bst`).
- A new release asset that is not added to `SHA256SUMS` in
  `oci/bluefin-server-image.bst`.
- Keys committed anywhere outside the gitignored `files/boot-keys/`.

## Verification

- [ ] `just validate` resolves the BuildStream graph without errors.
- [ ] `just dogfood-check` passes.
- [ ] `just dogfood-install NEXT=<dir>` passes when changing install or update logic.
- [ ] Exported `dist/diskless/` contains the OS DDI, both UKIs, the netboot ESP, `efi-keys/`, and `SHA256SUMS`.

## See also

- [ddi-installer.md](ddi-installer.md) — boot, install, and update architecture.
- [CONTEXT.md](../../CONTEXT.md) — canonical project domain glossary (OS DDI, Installer, Netboot UKI, Disk UKI).
