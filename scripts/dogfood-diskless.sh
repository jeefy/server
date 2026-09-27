#!/usr/bin/env bash
# Boot a Bluefin Server build diskless in QEMU, the way a PXE/HTTP-booted
# node would: firmware -> signed systemd-boot -> signed UKI -> initrd pulls
# bluefin-server_<ver>.raw over HTTP into RAM -> dm-verity /usr, tmpfs root.
#
# Secure Boot firmware starts in setup mode; systemd-boot enrolls the dev
# keys from the ESP (secure-boot-enroll if-safe) and reboots, so every
# later boot is verified. The UKI's cmdline is locked, so the download URL
# is handed over as the import.pull system credential via SMBIOS.
#
# Usage: dogfood-diskless.sh <dir with .raw/.efi/.esp.raw> [--check]
#   --check  headless: exit 0 once the node reaches a login prompt with no failed units
set -euo pipefail

dir="$(realpath "${1:?usage: $0 <artifact dir> [--check]}")"
mode="${2:-interactive}"
port="${DOGFOOD_PORT:-8765}"
mem="${DOGFOOD_MEM:-4096}"
timeout_s="${DOGFOOD_TIMEOUT:-600}"

esp="$(ls "${dir}"/bluefin-server-netboot_*.esp.raw | tail -n1)"
ver="${esp##*/bluefin-server-netboot_}"; ver="${ver%.esp.raw}"
image="bluefin-server_${ver}.raw"
[ -f "${dir}/${image}" ] || { echo "ERROR: ${dir}/${image} missing" >&2; exit 1; }

first_existing() { for f in "$@"; do [ -f "$f" ] && { echo "$f"; return 0; }; done; return 1; }
code="${OVMF_CODE:-$(first_existing \
    /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd \
    /usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
    /usr/share/OVMF/OVMF_CODE.secboot.fd \
    /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd)}" || { echo "ERROR: no Secure Boot OVMF_CODE found (set OVMF_CODE)" >&2; exit 1; }
vars_tmpl="${OVMF_VARS:-$(first_existing \
    /usr/share/edk2/ovmf/OVMF_VARS.fd \
    /usr/share/OVMF/OVMF_VARS_4M.fd \
    /usr/share/OVMF/OVMF_VARS.fd \
    /usr/share/edk2/x64/OVMF_VARS.4m.fd)}" || { echo "ERROR: no blank OVMF_VARS found (set OVMF_VARS)" >&2; exit 1; }

work="$(mktemp -d /tmp/bluefin-dogfood.XXXXXX)"
trap 'kill "${http_pid:-0}" 2>/dev/null || true; rm -rf "${work}"' EXIT
cp "${vars_tmpl}" "${work}/vars.fd"
cp "${esp}" "${work}/esp.raw"

(cd "${dir}" && exec python3 -m http.server --bind 127.0.0.1 "${port}" >"${work}/http.log" 2>&1) &
http_pid=$!

pull="raw,,machine,,verify=no,,blockdev:rootdisk:http://10.0.2.2:${port}/${image}"
qemu=(qemu-system-x86_64
    -machine q35,smm=on,accel=kvm -cpu host -m "${mem}" -smp 2
    -global driver=cfi.pflash01,property=secure,value=on
    -drive if=pflash,format=raw,unit=0,readonly=on,file="${code}"
    -drive if=pflash,format=raw,unit=1,file="${work}/vars.fd"
    -drive if=virtio,format=raw,file="${work}/esp.raw"
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0
    -smbios "type=11,value=io.systemd.credential:import.pull=${pull}"
    -nographic)

echo "Serving ${dir} on :${port}; booting ${image} (Secure Boot, setup mode)"
if [ "${mode}" != "--check" ]; then
    "${qemu[@]}"
    exit
fi

probe_unit='[Unit]
Description=Dogfood boot probe
After=multi-user.target
[Service]
Type=oneshot
StandardOutput=tty
TTYPath=/dev/ttyS0
ExecStart=/bin/sh -c "echo PROBE secureboot=$(bootctl status 2>/dev/null | sed -n \"s/.*Secure Boot: *//p\" | head -n1); echo PROBE lockdown=$(cat /sys/kernel/security/lockdown); echo PROBE usr=$(findmnt -no SOURCE,FSTYPE,OPTIONS /usr); echo PROBE root=$(findmnt -no FSTYPE /); echo PROBE verity=$(veritysetup status usr | sed -n \"s/^ *status: *//p\"); echo PROBE os=$(. /usr/lib/os-release; echo $IMAGE_ID $IMAGE_VERSION); echo PROBE failed=$(systemctl --failed --no-legend | wc -l)"
[Install]
WantedBy=multi-user.target'
probe_b64="$(printf '%s\n' "${probe_unit}" | base64 -w0)"

"${qemu[@]}" -serial "file:${work}/serial.log" -monitor none -display none \
    -smbios "type=11,value=io.systemd.credential.binary:systemd.extra-unit.dogfood-probe.service=${probe_b64}" \
    </dev/null >/dev/null 2>&1 &
qemu_pid=$!
deadline=$(( $(date +%s) + timeout_s ))
status=1
while kill -0 "${qemu_pid}" 2>/dev/null && [ "$(date +%s)" -lt "${deadline}" ]; do
    if grep -aq 'PROBE failed=' "${work}/serial.log" 2>/dev/null; then
        status=0
        break
    fi
    sleep 2
done
kill "${qemu_pid}" 2>/dev/null || true
wait "${qemu_pid}" 2>/dev/null || true
sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "${work}/serial.log" | tr -d '\r' > "${dir}/dogfood-serial.log"
grep -a 'GET ' "${work}/http.log" > "${dir}/dogfood-http.log" || true
failed="$(grep -a '\[FAILED\]' "${dir}/dogfood-serial.log" || true)"
grep -ao 'PROBE .*' "${dir}/dogfood-serial.log" || true
if [ "${status}" = 0 ] && [ -z "${failed}" ] && grep -aq 'PROBE failed=0' "${dir}/dogfood-serial.log"; then
    echo "PASS: booted diskless with no failed units (serial log: ${dir}/dogfood-serial.log)"
elif [ "${status}" = 0 ]; then
    echo "FAIL: booted, but units failed:" >&2
    echo "${failed}" >&2
    status=1
else
    echo "FAIL: boot probe did not report within ${timeout_s}s (serial log: ${dir}/dogfood-serial.log)" >&2
    tail -n 40 "${dir}/dogfood-serial.log" >&2
fi
exit "${status}"
