#!/usr/bin/env bash
# Upload the key-free BuildStream artifacts this build produced, and that no
# cache already serves, to the project's artifact cache.
#
#   CASD_CLIENT_CERT=<pem> CASD_CLIENT_KEY=<pem> bst-cache-push.sh
#
# .github/workflows/build.yml runs this after `just export-image` on pushes
# to main only, with the mTLS client credentials of the `bst-cache`
# environment. The rules are in "Build time and caches" in
# docs/skills/ci-tooling.md:
#
#  - The push configuration exists only while this script runs and is only
#    passed to `bst artifact push` below. It is never active during
#    `bst build`, which would upload every artifact it builds, including
#    bluefin-server/keys/boot-keys.bst.
#  - Only an explicit element list is pushed (--deps none), computed by
#    .github/scripts/cache-push-allowlist.py: no key-bearing or
#    version-stamped element and nothing that depends on one.
#  - Of those, only the artifacts cached locally that no remote serves yet
#    are pushed. A fresh CI runner pulls every artifact a remote has, so this
#    is exactly what the build compiled (FSDK's kernel, for one). It is asked
#    of the remotes themselves, by `bst artifact show` with an empty cache
#    directory, rather than read off the build log: that holds on a warm
#    cache too, and does not depend on log wording.
#
# BST_CACHE_PUSH_URL / BST_CACHE_PULL_URL override the cache endpoints for a
# local rehearsal against a throwaway cache server; a plain http:// push URL
# gets no client certificate, which BuildStream refuses on insecure channels.
set -euo pipefail

: "${CASD_CLIENT_CERT:?CASD_CLIENT_CERT is required}"
: "${CASD_CLIENT_KEY:?CASD_CLIENT_KEY is required}"
push_url="${BST_CACHE_PUSH_URL:-https://cache.projectbluefin.io:11002}"
pull_url="${BST_CACHE_PULL_URL:-https://cache.projectbluefin.io:11001}"

cd "$(dirname "$0")/.."
allowlist=(python3 .github/scripts/cache-push-allowlist.py)
targets=(oci/bluefin-server-image.bst oci/k0s-sysext.bst oci/kubestellar-sysext.bst oci/zfs-sysext.bst oci/kubeadm-sysext.bst)

# Inside the checkout, which `just bst` mounts at /src; gitignored, never
# under dist/, removed on exit and again by the workflow's cleanup step.
dir=.bst-cache-push
rm -rf "${dir}"
trap 'rm -rf "${dir}"' EXIT
(umask 077 && mkdir "${dir}" \
    && printf '%s\n' "${CASD_CLIENT_CERT}" > "${dir}/client.crt" \
    && printf '%s\n' "${CASD_CLIENT_KEY}" > "${dir}/client.key")

connection_config='connection-config: {keepalive-time: 180, retry-limit: 5, retry-delay: 1000, request-timeout: 180}'

"${allowlist[@]}" format > "${dir}/format"
just bst show --deps all --format "'$(cat "${dir}/format")'" "${targets[@]}" > "${dir}/graph"
"${allowlist[@]}" allowlist --cached-only --explain < "${dir}/graph" > "${dir}/candidates"
if [ ! -s "${dir}/candidates" ]; then
    echo "No key-free artifacts are cached locally; nothing to upload."
    exit 0
fi

# An empty cache directory, so every candidate's state comes from the
# remotes: the ones project.conf and the junctioned projects recommend, plus
# this cache's pull endpoint, which BuildStream otherwise only consults for
# this project's own elements.
cat > "${dir}/probe.conf" <<EOF
cachedir: /src/${dir}/probe-cache
logdir: /src/${dir}/probe-logs
artifacts:
  servers:
    - url: ${pull_url}
      ${connection_config}
EOF
mapfile -t candidates < "${dir}/candidates"
BST_FLAGS="--config /src/${dir}/probe.conf" \
    just bst artifact show --deps none "${candidates[@]}" > "${dir}/probe"
"${allowlist[@]}" unpublished < "${dir}/probe" | grep -Fx -f "${dir}/candidates" > "${dir}/push" || true
if [ ! -s "${dir}/push" ]; then
    echo "All ${#candidates[@]} key-free artifacts are already cached remotely; nothing to upload."
    exit 0
fi

auth=""
if [[ "${push_url}" == https://* ]]; then
    auth="
          auth:
            client-key: /src/${dir}/client.key
            client-cert: /src/${dir}/client.crt"
fi

# Remotes are resolved per BuildStream project: a junctioned project's
# elements (FSDK's kernel) only push to a remote configured for that project.
{
    echo "projects:"
    while read -r project; do
        cat <<EOF
  ${project}:
    artifacts:
      servers:
        - url: ${push_url}
          push: true
          ${connection_config}${auth}
EOF
    done < <("${allowlist[@]}" projects < "${dir}/graph")
} > "${dir}/push.conf"

echo "BuildStream push configuration:"
cat "${dir}/push.conf"
mapfile -t push < "${dir}/push"
echo "Uploading ${#push[@]} of ${#candidates[@]} locally cached key-free artifacts to ${push_url}:"
printf '  %s\n' "${push[@]}"
BST_FLAGS="--config /src/${dir}/push.conf --on-error continue" \
    just bst artifact push --deps none "${push[@]}"
