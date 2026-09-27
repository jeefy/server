---
name: architecture-roadmap
description: Roadmap for future Bluefin Server architecture work. Use when planning long-lead systemd-native capabilities.
metadata:
  type: reference
  status: stable
  last_updated: "2026-09-27"
  context7-sources:
    - /systemd/systemd
---

# Architecture Roadmap

Status: current roadmap.

This file captures planned architecture work and the rationale behind it. Verified implementation rules now live in [systemd-sysupdate-verification.md](systemd-sysupdate-verification.md), [tpm2-credential-sealing.md](tpm2-credential-sealing.md), and [systemd-sysext-extensions.md](systemd-sysext-extensions.md).
The source-verified gap analysis lives in [gap-analysis-distros.md](gap-analysis-distros.md).

## Done

For reference, so future planning does not redo them:

- A/B usr slots with `systemd-sysupdate` and boot-counted automatic rollback (`files/os/repart.d/`, `files/os/sysupdate.d/`).
- Read-only erofs `/usr` verified by dm-verity, pinned by `usrhash=` in the signed UKIs.
- Diskless network boot (`rd.systemd.pull` of the OS DDI into RAM) and diskless-native install via `systemd-sysinstall`.
- Secure Boot end to end (signed systemd-boot, signed UKIs, signed modules, `lockdown=integrity`).
- Opt-in Ignition provisioning via system credentials.

## Planned work

Priorities are derived from [gap-analysis-distros.md](gap-analysis-distros.md).

| # | Item | Rationale / source gap |
|---|------|------------------------|
| 1 | k0s role units (controller vs worker) and splitting the KubeStellar/Argo CD/kiosk stack into its own sysext | The k0s sysext currently carries both the runtime and the management stack; they version independently. |
| 2 | OCI image output alongside the raw artifacts | Factory pipelines consume OCI; the release set is currently raw files only. |
| 3 | SHA256SUMS signature verification for the diskless `rd.systemd.pull` download | The pull runs with `verify=no`; `/usr` integrity is still enforced by the pinned `usrhash=` and dm-verity, but the download stream itself is unverified. |
| 4 | TPM2-sealed /var on installed nodes | Credential sealing exists (`tpm2-credential-sealing.md`); persistent state is not yet bound to the TPM. |
| 5 | aarch64 build axis | `project.conf` and `include/arch.yml` already model it; no CI coverage yet. |
| 6 | Booty HTTP-boot integration | [Booty](https://github.com/jeefy/booty) is the intended PXE/HTTP-boot server (netboot UKI + `import.pull` credential + optional `ignition.config.url`); the hand-off is documented but not yet automated. |
| 7 | Credential provisioning smoke tests on real hardware | SSH keys, static network, and firstboot settings are wired through systemd credentials; TPM2-sealed credential decryption still needs hardware proof. |
| 8 | Native reboot coordination for non-Kubernetes and single-node hosts | Kured only covers Kubernetes nodes; no FleetLock/locksmith equivalent. |

## Status notes

- The current tree intentionally favors a small, verifiable core: verity-sealed `/usr`, A/B slots, signed boot chain, opt-in sysexts.
- Any implementation work should preserve the current systemd-native model and avoid custom daemons.
- See [gap-analysis-distros.md](gap-analysis-distros.md) for the source-verified comparison that produced this list.

## See also

- [gap-analysis-distros.md](gap-analysis-distros.md) — source-verified distro comparison.
- [CONTEXT.md](../../CONTEXT.md) — canonical project domain glossary.
