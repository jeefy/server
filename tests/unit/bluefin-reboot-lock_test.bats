#!/usr/bin/env bats
#
# Unit tests for files/os/update-check/usr/libexec/bluefin-reboot-lock.
#
# curl and systemd-id128 are stubs on PATH. The curl stub stands in for the
# FleetLock server: it records its arguments (one per line) in CURL_ARGS and
# answers with REPLY_BODY and HTTP status REPLY_CODE, the way the client's
# `-w '\n%{http_code}'` prints them; CURL_EXIT makes the transfer itself fail.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    SCRIPT="${REPO_ROOT}/files/os/update-check/usr/libexec/bluefin-reboot-lock"
    STUB_DIR="${BATS_TEST_TMPDIR}/bin"
    CONF="${BATS_TEST_TMPDIR}/reboot-lock.conf"
    CREDS="${BATS_TEST_TMPDIR}/credentials"
    export CURL_ARGS="${BATS_TEST_TMPDIR}/curl.args"
    mkdir -p "${STUB_DIR}" "${CREDS}"

    cat > "${STUB_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${CURL_ARGS}"
if [ "${CURL_EXIT:-0}" != 0 ]; then
    echo "curl: (7) Failed to connect" >&2
    printf '\n000'
    exit "${CURL_EXIT}"
fi
printf '%s\n%s' "${REPLY_BODY:-}" "${REPLY_CODE:-200}"
EOF
    cat > "${STUB_DIR}/systemd-id128" <<'EOF'
#!/usr/bin/env bash
[ "$1" = machine-id ] && [[ "$2" == --app-specific=* ]] || exit 1
echo 0123456789abcdef0123456789abcdef
EOF
    chmod +x "${STUB_DIR}"/*
}

lock() {
    run env PATH="${STUB_DIR}:${PATH}" BLUEFIN_REBOOT_LOCK_CONF="${CONF}" \
        CREDENTIALS_DIRECTORY="${CREDS}" bash "${SCRIPT}" "$@"
}

# The argument after <flag> in the recorded curl call.
arg() {
    awk -v flag="$1" 'prev == flag { print; exit } { prev = $0 }' "${CURL_ARGS}"
}

@test "without a server both verbs do nothing and succeed" {
    lock acquire
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"no FleetLock server configured"* ]]
    [ ! -e "${CURL_ARGS}" ]
    lock release
    [ "${status}" -eq 0 ]
    [ ! -e "${CURL_ARGS}" ]
}

@test "a config file with only comments is no server" {
    printf '# URL=https://<fleetlock-host>\nGROUP=web\n' > "${CONF}"
    lock acquire
    [ "${status}" -eq 0 ]
    [ ! -e "${CURL_ARGS}" ]
}

@test "acquire posts the FleetLock pre-reboot request and holds the slot on 200" {
    printf 'URL=https://fleetlock.example/base/\n' > "${CONF}"
    lock acquire
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"holding a reboot slot on https://fleetlock.example/base"* ]]
    [ "$(tail -n 1 "${CURL_ARGS}")" = "https://fleetlock.example/base/v1/pre-reboot" ]
    grep -qx 'fleet-lock-protocol: true' "${CURL_ARGS}"
    [ "$(arg --data-binary)" = '{"client_params":{"id":"0123456789abcdef0123456789abcdef","group":"default"}}' ]
    [ "$(arg --proto)" = "=http,https" ]
    [ -z "$(grep -xE -- '--location|-L' "${CURL_ARGS}")" ]
}

@test "release posts the steady-state request" {
    printf 'URL=http://fleetlock.example\nGROUP=db-1\n' > "${CONF}"
    lock release
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"released the reboot slot"* ]]
    [ "$(tail -n 1 "${CURL_ARGS}")" = "http://fleetlock.example/v1/steady-state" ]
    [ "$(arg --data-binary)" = '{"client_params":{"id":"0123456789abcdef0123456789abcdef","group":"db-1"}}' ]
}

@test "a full semaphore refuses the reboot and logs the server's reason" {
    printf 'URL="https://fleetlock.example"\n' > "${CONF}"
    REPLY_CODE=409 REPLY_BODY='{"kind":"failed_lock_semaphore_full","value":"semaphore currently full"}' lock acquire
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"<4>no reboot slot on https://fleetlock.example"* ]]
    [[ "${output}" == *"HTTP 409"*"semaphore currently full"*"not rebooting"* ]]
}

@test "any answer but 200 fails a release so the unit retries" {
    printf 'URL=https://fleetlock.example\n' > "${CONF}"
    REPLY_CODE=500 lock release
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"<3>"*"not released: HTTP 500"* ]]
}

@test "an unreachable server refuses the reboot" {
    printf 'URL=https://fleetlock.example\n' > "${CONF}"
    CURL_EXIT=7 lock acquire
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"cannot reach FleetLock server https://fleetlock.example/v1/pre-reboot"* ]]
    CURL_EXIT=7 lock release
    [ "${status}" -eq 1 ]
}

@test "credentials override the config file" {
    printf 'URL=https://file.example\nGROUP=file\n' > "${CONF}"
    printf 'https://cred.example\n' > "${CREDS}/bluefin.reboot-lock.url"
    printf 'workers\n' > "${CREDS}/bluefin.reboot-lock.group"
    lock acquire
    [ "${status}" -eq 0 ]
    [ "$(tail -n 1 "${CURL_ARGS}")" = "https://cred.example/v1/pre-reboot" ]
    [[ "$(arg --data-binary)" == *'"group":"workers"'* ]]
}

@test "a URL credential alone configures the lock" {
    printf 'https://cred.example' > "${CREDS}/bluefin.reboot-lock.url"
    lock acquire
    [ "${status}" -eq 0 ]
    [[ "$(arg --data-binary)" == *'"group":"default"'* ]]
}

@test "a group outside the protocol's alphabet is refused without a request" {
    printf 'URL=https://fleetlock.example\nGROUP=web servers\n' > "${CONF}"
    lock acquire
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"must match"* ]]
    [ ! -e "${CURL_ARGS}" ]
}

@test "a URL that is not http(s) is refused without a request" {
    printf 'URL=file:///etc/passwd\n' > "${CONF}"
    lock acquire
    [ "${status}" -eq 1 ]
    [ ! -e "${CURL_ARGS}" ]
}

@test "no client id means no reboot" {
    printf 'URL=https://fleetlock.example\n' > "${CONF}"
    printf '#!/usr/bin/env bash\nexit 1\n' > "${STUB_DIR}/systemd-id128"
    lock acquire
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"cannot derive the FleetLock client id"* ]]
    [ ! -e "${CURL_ARGS}" ]
}

@test "an unknown verb is a usage error" {
    lock reboot
    [ "${status}" -eq 2 ]
}
