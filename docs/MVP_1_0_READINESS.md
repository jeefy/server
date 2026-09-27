# Bluefin Server MVP 1.0 Readiness Audit

This audit tracks the gap between the current tree and a first public/usable MVP 1.0 release.

## MVP 1.0 bar

1. **Reproducible build path** — documented command or CI job that produces the OS DDI, signed UKIs, netboot ESP, and sysexts.
2. **Signed release artifacts** — combined `SHA256SUMS` + detached GPG signature published to GitHub Releases.
3. **Automated boot verification** — at least one non-human test that proves the image boots and installs.
4. **Functional update path** — host can pull the signed manifest and apply an OS update without manual intervention.
5. **Basic first-boot provisioning** — unattended way to set root credential and drop an SSH authorized key.
6. **Documented recovery** — A/B rollback or reinstall path for a failed update.

## Current state

| Check | Status | Evidence |
|---|---|---|
| Element graph resolves | ✅ | `just validate` succeeds for the image set and both sysexts |
| Release workflow lint | ✅ | `actionlint .github/workflows/build.yml` clean |
| Release path exists | ✅ | `.github/workflows/build.yml` builds, signs, publishes immutable `v<image-version>` GitHub Releases |
| Automated boot test | ✅ | `boot-test` job in `build.yml` runs `scripts/dogfood-diskless.sh --check` and `scripts/dogfood-install.sh` on every PR and push to main; locally `just dogfood-check` / `just dogfood-install` |
| A/B rollback | ✅ | `files/os/repart.d/` provisions usr slots A+B; `systemd-sysupdate` fills the inactive slot and UKI boot counting (`TriesLeft=3` in `files/os/sysupdate.d/20-uki.transfer`) rolls back failed boots; proven by `scripts/dogfood-install.sh <dir> <next> <broken>` |
| Read-only /usr | ✅ | erofs + dm-verity pinned by `usrhash=` in the signed UKIs (`elements/oci/bluefin-server-usr.bst`, `elements/oci/bluefin-server-boot.bst`) |
| First-boot SSH keys | ✅ | Ignition (`ignition.config` / `ignition.config.url` credentials; `tests/fixtures/ignition/var-on-disk.ign`) and `tmpfiles.extra` / sysusers credentials (`elements/bluefin-server/os-creds-prov.bst`) |

Competitor context: [gap-analysis-distros.md](skills/gap-analysis-distros.md)

## Verdict

**Alpha state — on track for MVP 1.0.** The build path, signed releases, automated boot verification, A/B rollback, read-only /usr, and unattended provisioning are all implemented and exercised in CI. Remaining work is hardening: TPM2-sealed state, reboot coordination outside Kubernetes, and real-hardware boot proofs.

## Roadmap

Priority order. Each item depends on the ones above it.

### Phase A: build path and core artifacts (Complete)

- [x] Merge-contract graph validation (`just validate`) passes clean.
- [x] Add the k0s and OpenZFS sysexts to the build and validation pipeline.
- [x] Release workflow builds, signs, and publishes immutable GitHub Releases.

### Phase B: automated boot verification (Complete)

- [x] Secure Boot QEMU diskless boot check (`scripts/dogfood-diskless.sh --check`).
- [x] Diskless -> install -> disk boot check (`scripts/dogfood-install.sh`).
- [x] Boot test wired into `build.yml` as the `boot-test` job gating releases.

### Phase C: update/rollback and provisioning (Complete)

- [x] usr slot B created on first disk boot; `systemd-sysupdate` stages into the inactive slot.
- [x] /usr is read-only erofs under dm-verity; the persistent root is xfs.
- [x] Boot-counted UKIs roll back a failed update automatically.
- [x] SSH authorized keys via Ignition and `systemd-creds` (`tmpfiles.extra`).

### Phase D: release discipline

- [ ] TPM2-sealed /var and credential decryption proof on real hardware.
- [ ] Reboot coordination for non-Kubernetes hosts.
- [ ] Tag `v1.0.0-MVP` once Phase D items land.
- [ ] Publish release notes: verified boot path, trust model, known gaps.

## Related files

- Downstream factory CI repository Argo workflow templates
- `projectbluefin/server/.github/workflows/build.yml`
- `docs/skills/gap-analysis-distros.md`
- `docs/skills/architecture-roadmap.md`
