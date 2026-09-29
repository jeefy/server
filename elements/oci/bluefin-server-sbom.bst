kind: collect_manifest
description: |
  SPDX 2.3 SBOM of one release set, written by the collect_manifest plugin
  that freedesktop-sdk uses for its own CVE manifests
  (buildstream-plugins-community, source provenance API).

  One SPDX package per source of every element in the runtime closure of
  the dependencies below: name, version (from the git-describe ref or the
  tarball name), download location and source kind. Local sources are
  listed by path.

  The dependencies are the payload of the release set, not the tools that
  assemble it: the /usr and initrd stacks, the kernel, and the sysext
  payloads. Build-only elements (signing keys, image tooling) are not
  runtime dependencies of these and never appear.

  oci/bluefin-server-image.bst stamps creationInfo.created and ships the
  result as bluefin-server_<ver>.spdx.json inside the signed SHA256SUMS.

(@):
- include/image.yml

build-depends:
- bluefin-server/os-stack.bst
- bluefin-server/initrd/initrd-stack.bst
- freedesktop-sdk.bst:components/linux.bst
- k0s/k0s-bin.bst
- oci/kubestellar-sysext.bst
- kubeadm/kubeadm-bin.bst
- zfs/openzfs.bst

config:
  path: /bluefin-server.spdx.json
  output-type: spdx
  spdx-info:
    name: bluefin-server-%{image-version}
    data-license: CC0-1.0
    doc-namespace: https://github.com/projectbluefin/server/spdx/bluefin-server-%{image-version}
    creators:
    - "Organization: Project Bluefin"
    - "Tool: buildstream-plugins-community-collect_manifest"
