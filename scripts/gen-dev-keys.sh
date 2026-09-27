#!/usr/bin/env bash
# Generate a local, throwaway Secure Boot + kernel module signing key set
# under files/boot-keys/ (gitignored). Dogfood builds sign the UKI and
# systemd-boot with DB and kernel modules with linux-module-cert; the
# firmware enrolls PK/KEK/DB from the ESP on first boot.
#
# Layout (matches freedesktop-sdk's files/boot-keys convention):
#   files/boot-keys/{PK,KEK,DB}.{key,crt}
#   files/boot-keys/linux-module-cert.key         private, never staged into the kernel build
#   files/boot-keys/modules/linux-module-cert.crt public, baked into the kernel's trusted keyring
#
# Changing modules/linux-module-cert.crt changes the kernel's cache key and
# forces a kernel rebuild, so existing keys are kept unless --force is given.
set -euo pipefail

dir="$(cd "$(dirname "$0")/.." && pwd)/files/boot-keys"
force=0
[ "${1:-}" = "--force" ] && force=1

if [ -e "${dir}/DB.key" ] && [ "${force}" = 0 ]; then
    echo "Keys already exist in ${dir}; pass --force to regenerate (rebuilds the kernel)."
    exit 0
fi

mkdir -p "${dir}/modules"
chmod 0700 "${dir}"
umask 077

owner="${USER:-dev}@$(hostname -s 2>/dev/null || echo localhost)"

for name in PK KEK DB; do
    openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
        -subj "/CN=Bluefin Server dev ${name} (${owner})/" \
        -keyout "${dir}/${name}.key" -out "${dir}/${name}.crt" 2>/dev/null
done

openssl req -new -x509 -newkey rsa:4096 -nodes -sha512 -days 3650 \
    -subj "/CN=Bluefin Server dev kernel modules (${owner})/" \
    -addext "keyUsage=digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "${dir}/linux-module-cert.key" -out "${dir}/modules/linux-module-cert.crt" 2>/dev/null

chmod 0644 "${dir}"/*.crt "${dir}/modules/linux-module-cert.crt"
echo "Generated dev keys in ${dir}"
