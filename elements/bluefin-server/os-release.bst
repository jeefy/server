kind: manual
description: |
  Bluefin Server os-release. IMAGE_ID/IMAGE_VERSION identify the image to
  systemd-sysupdate and systemd-sysext; extensions match on ID=bluefin-server.

(@):
- include/arch.yml
- include/image.yml

build-depends:
- base/base-stack.bst

variables:
  strip-binaries: ""

config:
  install-commands:
  - mkdir -p "%{install-root}/usr/lib"
  - |
    cat <<EOF > "%{install-root}/usr/lib/os-release"
    NAME="Bluefin Server"
    ID=bluefin-server
    VERSION="%{image-version}"
    VERSION_ID=%{image-version}
    PRETTY_NAME="Bluefin Server %{image-version}"
    IMAGE_ID=bluefin-server
    IMAGE_VERSION=%{image-version}
    ARCHITECTURE=%{systemd-arch}
    ANSI_COLOR="0;38;5;33"
    HOME_URL="https://github.com/projectbluefin/server"
    BUG_REPORT_URL="https://github.com/projectbluefin/server/issues"
    EOF
