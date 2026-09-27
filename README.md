# Bluefin Server
> Amargasaurus cazaui

**An image-based Linux server OS built like a container, composed from freedesktop-sdk.**

Bluefin Server targets the same use-case space as Flatcar Container Linux, Fedora CoreOS, and Talos, and is built with [BuildStream 2](https://buildstream.build/). Its entire userspace, kernel, and boot chain compose from [freedesktop-sdk](https://freedesktop-sdk.freedesktop.org/) (FSDK 26.08, systemd v261) components. No other distro's binaries ship in the image.

It is [DDI first](https://0pointer.net/blog/fitting-everything-together.html) and diskless-first: one build produces a verity-sealed `/usr` image, two signed UKIs, and an OS DDI that a node pulls into RAM over HTTP. Rebooting is how a diskless node updates. Installing to disk is optional.

> The only thing worse than a nightmare is a factory of nightmares that makes other nightmares

![armargasaurus](https://en.wikipedia.org/wiki/Amargasaurus#/media/File:Dicraeosauridae_Scale.svg)

## Release status: Alpha

Bluefin Server is currently in **Alpha**:
- **Trust model**: every boot is Secure Boot verified end to end (signed systemd-boot, signed UKIs, dm-verity `/usr` pinned by `usrhash=` on the locked kernel command line). Releases publish a GPG-signed `SHA256SUMS` manifest for `systemd-sysupdate`.
- **Suitability**: Alpha builds are intended for evaluation, testing, and factory validation. Not yet recommended for production workloads.
- **Readiness roadmap**: Track completed criteria and remaining gates toward 1.0 in [`docs/MVP_1_0_READINESS.md`](docs/MVP_1_0_READINESS.md).

## What it is

- **Diskless-first boot** — the netboot UKI pulls `bluefin-server_<ver>.raw` into RAM with `rd.systemd.pull`, mounts a dm-verity erofs `/usr`, and runs from tmpfs. A diskless node updates by rebooting into a newer image.
- **Optional disk install with A/B rollback** — a running diskless node *is* the installer: `systemd-sysinstall --definitions=/run/bluefin/boot/bluefin/repart.d` copies `/usr` into slot A. The first disk boot creates slot B and a persistent xfs root. `systemd-sysupdate` fills the inactive slot, and UKI boot counting rolls back a failed update automatically.
- **Secure Boot on** — signed systemd-boot, signed UKIs, signed kernel modules, `lockdown=integrity`.
- **Opt-in per-node state via Ignition** — pass an `ignition.config` / `ignition.config.url` system credential and Ignition runs in the initrd on every boot; configs must be idempotent.
- **Opt-in sysexts** — k0s (Kubernetes) and OpenZFS ship as separate `systemd-sysext` images, never in the base `/usr`.

> **Remote diagnostics:** OpenSSH is installed for on-demand diagnostics, but is disabled by default via systemd presets. It can be started manually with `systemctl start sshd` when remote access is needed. See [`docs/skills/factory-integration.md`](docs/skills/factory-integration.md).

## Quick start

You need only `podman` and [`just`](https://github.com/casey/just). BuildStream runs inside the FSDK `bst2` container, so BuildStream is not installed locally.

```sh
just validate        # resolve the element graph
just export-image    # build the release set into dist/diskless/
just dogfood-check   # headless QEMU diskless boot with Secure Boot
just dogfood-install # diskless boot, install to disk, boot it (QEMU)
```

See [`AGENTS.md`](AGENTS.md) for the full build command matrix, hard rules, and agent skill routing.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the contributor checklist, Conventional Commit rules, and [`docs/skills/index.md`](docs/skills/index.md) for task-specific guidance.

## Security and release trust

- **Signed boot chain**: Secure Boot keys enroll from the ESP on first boot (`secure-boot-enroll if-safe`); local builds use throwaway keys from `just gen-dev-keys`.
- **Signed manifests**: GitHub Actions builds all release artifacts, generates a combined `SHA256SUMS` manifest, and signs it with GPG before publishing to GitHub Releases.
- **Sysupdate verification**: Installed nodes verify updates against the signed manifest; see [`docs/skills/systemd-sysupdate-verification.md`](docs/skills/systemd-sysupdate-verification.md) for details.
- **Vulnerability disclosure**: See [`SECURITY.md`](SECURITY.md) for policy details and how to report security issues.

## License

Apache-2.0.
