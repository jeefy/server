kind: manual
description: |
  Weekly first-party countme reporting.

  The reporter is not defined here. It is taken from projectbluefin/common
  system_files/shared, the same unit and helper every other image ships, so this
  image counts through exactly the same bluefin-countme as the rest of the family.

  Common main ships that client gated to Dakota: the units carry
  ConditionOSRelease=ID=bluefin-dakota and ConditionPathExists=/run/ostree-booted,
  and the script exits unless image-name starts with "dakota" and it can prove a
  stable/testing stream from a bootc ref. This image is ID=bluefin-server,
  declares image-name "server" only, and is a DDI with no bootc, so the element
  installs drop-ins that clear the Dakota/ostree conditions and seds the two
  script gates to accept this image instead. It reports repo=server with no tag
  (a DDI has no container stream), the same metadata the original first-party
  reporter pinned here would have sent.

  The preset from common enables the timer; this image applies systemd presets,
  so no enablement symlink is needed.

sources:
  - kind: git_repo
    url: github:projectbluefin/common.git
    track: main
    ref: v2026.08-207-g725dbf68ccff8ae2ad74300430f984ee9ea8206c

build-depends:
  - base/base-stack.bst

depends:
  # The reporter reads image metadata with jq and sends the ping with curl.
  - freedesktop-sdk.bst:components/curl.bst
  - freedesktop-sdk.bst:components/jq.bst
  - bluefin-server/os-image-info.bst

variables:
  strip-binaries: ""

config:
  install-commands:
    - install -Dm755 system_files/shared/usr/libexec/bluefin-countme "%{install-root}%{prefix}/libexec/bluefin-countme"
    - install -Dm644 system_files/shared/usr/lib/systemd/system/bluefin-countme.service -t "%{install-root}%{prefix}/lib/systemd/system/"
    - install -Dm644 system_files/shared/usr/lib/systemd/system/bluefin-countme.timer -t "%{install-root}%{prefix}/lib/systemd/system/"
    - install -Dm644 system_files/shared/usr/lib/systemd/system-preset/03-bluefin-countme.preset -t "%{install-root}%{prefix}/lib/systemd/system-preset/"

    # This image is ID=bluefin-server, not ID=bluefin-dakota, and is not
    # ostree/bootc-managed. Clear the Dakota/ostree conditions so the units
    # actually run here; keep every other condition (opt-outs included).
    - |
      install -d "%{install-root}%{prefix}/lib/systemd/system/bluefin-countme.service.d" \
                 "%{install-root}%{prefix}/lib/systemd/system/bluefin-countme.timer.d"
    - |
      cat > "%{install-root}%{prefix}/lib/systemd/system/bluefin-countme.service.d/10-bluefin-server.conf" <<'EOF'
      [Unit]
      ConditionOSRelease=
      ConditionPathExists=
      ConditionPathExists=!/etc/projectbluefin/countme/disabled
      ConditionPathExists=!/etc/bluefin-countme-opt-out
      ConditionPathExists=!/etc/dakota-countme/disabled
      After=
      After=network-online.target

      [Service]
      # The client exits non-zero when the ping cannot be delivered (no route,
      # DNS down, endpoint unreachable); the timer retries daily and the client
      # throttles to one success per week, so a failed attempt is not a service
      # failure. Treat every exit status as success so a missed week never shows
      # up in systemctl --failed.
      SuccessExitStatus=0 1 2 3 4 5 6 7 8 28 35 52 56
      EOF
    - |
      cat > "%{install-root}%{prefix}/lib/systemd/system/bluefin-countme.timer.d/10-bluefin-server.conf" <<'EOF'
      [Unit]
      ConditionOSRelease=
      ConditionPathExists=
      ConditionPathExists=!/etc/projectbluefin/countme/disabled
      ConditionPathExists=!/etc/bluefin-countme-opt-out
      ConditionPathExists=!/etc/dakota-countme/disabled
      EOF

    # Adapt the shared Dakota-scoped client to this image: count the
    # "server" image name and report without a stream tag. A DDI delivered by
    # systemd-sysupdate has no booted container ref, so there is no tag to
    # wait on; reporting with repo=server alone is valid. The transform is
    # POSIX shell (the sandbox runs sh; sed/grep/awk are not installed). The
    # n1..n4 counters fail the build if common rewords any anchor.
    - |
      f="%{install-root}%{prefix}/libexec/bluefin-countme"
      n1=0; n2=0; n3=0; n4=0
      while IFS= read -r line; do
        case "$line" in
          'if [[ -z "$raw_name" ]] || [[ "$raw_name" != dakota* ]]; then')
            line='if [[ -z "$raw_name" ]] || [[ "$raw_name" != dakota* && "$raw_name" != "server" ]]; then'; n1=1 ;;
          'if [[ "$TAG" != "stable" && "$TAG" != "testing" ]]; then')
            line='if [[ "$TAG" != "stable" && "$TAG" != "testing" && "$raw_name" != "server" ]]; then'; n2=1 ;;
          'REPO="dakota"')
            line='REPO="server"'; n3=1 ;;
          *'tag=${TAG}'*)
            line="${line//'tag=${TAG}'/'tag=${TAG:-none}'}"; n4=1 ;;
        esac
        printf '%s\n' "$line"
      done < "$f" > "$f.new"
      mv "$f.new" "$f"
      chmod 755 "$f"
      [ "$n1" = 1 ] && [ "$n2" = 1 ] && [ "$n3" = 1 ] && [ "$n4" = 1 ] || {
        echo "ERROR: bluefin-countme anchors missing (n1=$n1 n2=$n2 n3=$n3 n4=$n4)" >&2; exit 1; }
