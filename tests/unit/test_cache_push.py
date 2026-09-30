"""Behavioural coverage for the BuildStream cache upload on main.

.github/scripts/cache-push-allowlist.py decides which artifacts main may
upload to cache.projectbluefin.io; scripts/bst-cache-push.sh does the upload
after the build. An allow-list mistake publishes signing keys to a cache every
build pulls from, so these tests pin: nothing key-bearing or depending on a
key element is listed, the public module certificate exemption only holds for
a certificate-only directory, and only unpublished allow-listed artifacts are
pushed, with a push config no other bst call sees. The workflow side is in
test_cache_push_workflow.py.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
ALLOWLIST = ROOT / ".github" / "scripts" / "cache-push-allowlist.py"
PUSH_SCRIPT = ROOT / "scripts" / "bst-cache-push.sh"

_spec = importlib.util.spec_from_file_location("cache_push_allowlist", ALLOWLIST)
cpa = importlib.util.module_from_spec(_spec)
sys.modules["cache_push_allowlist"] = cpa
_spec.loader.exec_module(cpa)

CERT = "-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----\n"
KEY = "-----BEGIN PRIVATE KEY-----\nMIIEfake\n-----END PRIVATE KEY-----\n"

FSDK = "freedesktop-sdk.bst"
KEYS = "bluefin-server/keys/boot-keys.bst"
MODULE_CERT = "bluefin-server/keys/linux-module-cert.bst"
KERNEL = f"{FSDK}:components/linux.bst"
KERNEL_MODULES = "bluefin-server/kernel-modules.bst"
OS_BASE = "bluefin-server/os-base.bst"
OS_IMAGE = "oci/bluefin-server-usr.bst"
OS_RELEASE = "bluefin-server/os-release.bst"
OS_STACK = "bluefin-server/os-stack.bst"
FILES_ALL = "bluefin-server/everything.bst"
UNRELATED = f"{FSDK}:components/zstd.bst"
K0S = "k0s/k0s-bin.bst"
JUNCTION = "plugins/buildstream-plugins.bst"


def bst_record(name, *, kind="manual", state="cached", build=(), run=(), local=(), stamped=False, project=None):
    project = project or ("freedesktop-sdk" if name.startswith(f"{FSDK}:") else "bluefin-server")
    variables = {"prefix": "/usr", "project-name": project}
    if stamped:
        variables["image-version"] = "26.09.1"
    sources = [{"kind": "local", "url": p, "medium": "local", "version-type": "cas-digest", "version": "ab/1"} for p in local]
    sources.append({"kind": "git_repo", "url": "https://example.invalid/x.git", "medium": "git", "version": "v1"})

    def dump(value):
        return yaml.safe_dump(value, default_flow_style=False).rstrip("\n")

    fields = {
        "name": f"\x1b[33m{name}\x1b[0m",
        "kind": kind,
        "state": f"\x1b[35m{state}\x1b[0m",
        "build-deps": dump(list(build)),
        "runtime-deps": dump(list(run)),
        "source-info": dump(sources),
        "vars": dump(variables),
    }
    return "\n".join(f"#@{key} {value}" for key, value in fields.items())


def synthetic_graph(kernel_state="cached"):
    return "\n".join(
        [
            bst_record(UNRELATED),
            bst_record(JUNCTION, kind="junction", state="junction"),
            bst_record(KEYS, kind="import", local=["files/boot-keys"]),
            bst_record(MODULE_CERT, kind="import", local=["files/boot-keys/modules"]),
            bst_record(KERNEL, kind="make", state=kernel_state, build=[UNRELATED, MODULE_CERT]),
            bst_record(KERNEL_MODULES, build=[KERNEL, KEYS]),
            bst_record(OS_BASE, kind="stack", run=[KERNEL_MODULES, UNRELATED]),
            bst_record(OS_RELEASE, local=["files/os/issue.d"], stamped=True),
            bst_record(OS_STACK, kind="stack", run=[OS_RELEASE, UNRELATED]),
            bst_record(OS_IMAGE, kind="script", build=[OS_BASE]),
            bst_record(FILES_ALL, kind="import", local=["files"]),
            bst_record(K0S, state="buildable", local=["files/k0s/sysext"], build=[UNRELATED]),
        ]
    )


@pytest.fixture
def repo(tmp_path):
    modules = tmp_path / "files" / "boot-keys" / "modules"
    modules.mkdir(parents=True)
    (modules / "linux-module-cert.crt").write_text(CERT)
    (tmp_path / "files" / "boot-keys" / "linux-module-cert.key").write_text(KEY)
    return tmp_path


def allowed(graph, repo_root):
    names, _ = cpa.allowlist(cpa.parse_graph(graph), repo_root)
    return names


def test_only_key_free_unstamped_elements_are_listed(repo):
    assert allowed(synthetic_graph(), repo) == [UNRELATED, MODULE_CERT, KERNEL, K0S]


def test_every_exclusion_names_its_cause(repo):
    _, excluded = cpa.allowlist(cpa.parse_graph(synthetic_graph()), repo)
    assert excluded == {
        KEYS: "secret: boot-keys element",
        FILES_ALL: "secret: local source files",
        OS_RELEASE: "version-stamped (include/image.yml)",
        JUNCTION: "junction",
        KERNEL_MODULES: f"depends on {KEYS}",
        OS_BASE: f"depends on {KERNEL_MODULES}",
        OS_IMAGE: f"depends on {OS_BASE}",
        OS_STACK: f"depends on {OS_RELEASE}",
    }


def test_direct_build_dependent_of_the_keys_is_excluded(repo):
    assert KERNEL_MODULES not in allowed(synthetic_graph(), repo)


def test_transitive_runtime_dependent_of_the_keys_is_excluded(repo):
    names = allowed(synthetic_graph(), repo)
    assert OS_BASE not in names
    assert OS_IMAGE not in names


def test_keys_element_is_excluded_by_name_even_without_local_sources(repo):
    graph = bst_record(KEYS, kind="import") + "\n" + bst_record(UNRELATED)
    assert allowed(graph, repo) == [UNRELATED]


@pytest.mark.parametrize("path", ["files", "files/", ".", "./files/boot-keys", "files/boot-keys/PK.key", "vendor/boot-keys"])
def test_any_local_source_touching_the_keys_is_secret(repo, path):
    graph = bst_record("bluefin-server/x.bst", local=[path]) + "\n" + bst_record(UNRELATED)
    assert allowed(graph, repo) == [UNRELATED]


def test_version_stamped_element_and_its_dependents_are_excluded(repo):
    names = allowed(synthetic_graph(), repo)
    assert OS_RELEASE not in names
    assert OS_STACK not in names


def test_junctions_are_never_listed(repo):
    assert JUNCTION not in allowed(synthetic_graph(), repo)


def test_module_cert_exemption_needs_a_certificate_only_directory(repo):
    (repo / "files" / "boot-keys" / "modules" / "linux-module-cert.key").write_text(KEY)
    names = allowed(synthetic_graph(), repo)
    assert MODULE_CERT not in names
    assert KERNEL not in names


def test_module_cert_exemption_rejects_a_key_inside_the_certificate_file(repo):
    (repo / "files" / "boot-keys" / "modules" / "linux-module-cert.crt").write_text(CERT + KEY)
    assert KERNEL not in allowed(synthetic_graph(), repo)


def test_module_cert_exemption_needs_the_directory(tmp_path):
    names = allowed(synthetic_graph(), tmp_path)
    assert MODULE_CERT not in names
    assert KERNEL not in names


def test_cached_only_drops_elements_this_build_did_not_cache(repo):
    graph = synthetic_graph()
    out = run_cli(["allowlist", "--cached-only", "--repo-root", str(repo)], graph)
    assert out.split() == [UNRELATED, MODULE_CERT, KERNEL]


def test_projects_are_those_owning_listed_elements(repo):
    out = run_cli(["projects", "--repo-root", str(repo)], synthetic_graph())
    assert out.split() == ["bluefin-server", "freedesktop-sdk"]


def test_unpublished_is_only_what_no_remote_has():
    show = "\x1b[91m  not cached\x1b[0m \x1b[33mfreedesktop-sdk.bst:components/linux.bst\x1b[0m\n" "   available k0s/k0s-bin.bst\n" "      cached zfs/openzfs.bst\n\n"
    assert run_cli(["unpublished"], show).split() == [KERNEL]


def test_graph_without_elements_is_an_error():
    result = subprocess.run([sys.executable, str(ALLOWLIST), "allowlist"], input="", capture_output=True, text=True)
    assert result.returncode != 0


def test_format_asks_bst_for_every_parsed_field():
    fmt = run_cli(["format"], "")
    for field in cpa.FIELDS:
        assert f"#@{field} %{{{field}}}" in fmt


def run_cli(args, stdin):
    return subprocess.run([sys.executable, str(ALLOWLIST), *args], input=stdin, capture_output=True, text=True, check=True).stdout


# A real-graph dump: BST_GRAPH=<file> after
#   just bst show --deps all --format "'$(python3 .github/scripts/cache-push-allowlist.py format)'" \
#     oci/bluefin-server-image.bst oci/k0s-sysext.bst oci/kubestellar-sysext.bst oci/zfs-sysext.bst oci/kubeadm-sysext.bst
@pytest.mark.skipif(not os.environ.get("BST_GRAPH"), reason="set BST_GRAPH to a `bst show` dump of the real graph")
def test_real_graph_excludes_every_key_consumer():
    elements = cpa.parse_graph(Path(os.environ["BST_GRAPH"]).read_text(encoding="utf-8"))
    names, excluded = cpa.allowlist(elements, ROOT)
    for key_consumer in (
        KEYS,
        KERNEL_MODULES,
        "bluefin-server/keys/efi-keys.bst",
        "bluefin-server/os-sd-boot-signed.bst",
        "bluefin-server/os-sysupdate-keys.bst",
        "zfs/openzfs-signed.bst",
        "oci/bluefin-server-boot.bst",
        "oci/bluefin-server-image.bst",
    ):
        assert key_consumer in elements and key_consumer in excluded
    assert KERNEL in names and MODULE_CERT in names
    for name in names:
        assert not set(elements[name].build_deps + elements[name].runtime_deps) & set(excluded), name
    print(f"\n{len(names)} of {len(elements)} elements allow-listed; excluded:")
    for name, reason in excluded.items():
        print(f"  {name}: {reason}")


FAKE_JUST = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import json, os, sys
    args = sys.argv[1:]
    assert args[0] == "bst", args
    flags = os.environ.get("BST_FLAGS", "")
    config = ""
    if "--config" in flags:
        path = flags.split("--config", 1)[1].split()[0]
        config = open(path.replace("/src/", os.getcwd() + "/", 1)).read()
    creds = {f: oct(os.stat(os.path.join(".bst-cache-push", f)).st_mode & 0o777) for f in os.listdir(".bst-cache-push")}
    with open(os.environ["FAKE_LOG"], "a") as log:
        log.write(json.dumps({"args": args[1:], "flags": flags, "config": config, "files": creds}) + "\\n")
    if args[1] == "show":
        sys.stdout.write(open(os.environ["FAKE_GRAPH"]).read())
    elif args[1:3] == ["artifact", "show"]:
        unpublished = os.environ["FAKE_UNPUBLISHED"].split()
        for name in [a for a in args[3:] if not a.startswith("-") and a != "none"]:
            print(("  not cached " if name in unpublished else "   available ") + name)
    elif args[1:3] == ["artifact", "push"]:
        sys.exit(int(os.environ.get("FAKE_PUSH_RC", "0")))
    """
)


@pytest.fixture
def push_env(tmp_path, repo):
    tree = tmp_path / "checkout"
    (tree / "scripts").mkdir(parents=True)
    (tree / ".github" / "scripts").mkdir(parents=True)
    shutil.copy(PUSH_SCRIPT, tree / "scripts")
    shutil.copy(ALLOWLIST, tree / ".github" / "scripts")
    shutil.copytree(repo / "files", tree / "files")
    bindir = tmp_path / "bin"
    bindir.mkdir()
    (bindir / "just").write_text(FAKE_JUST)
    (bindir / "just").chmod(0o755)
    graph = tmp_path / "graph"
    graph.write_text(synthetic_graph())
    env = dict(
        os.environ,
        PATH=f"{bindir}:{os.environ['PATH']}",
        FAKE_LOG=str(tmp_path / "log"),
        FAKE_GRAPH=str(graph),
        FAKE_UNPUBLISHED=f"{KERNEL} {MODULE_CERT} {KEYS} {KERNEL_MODULES}",
        CASD_CLIENT_CERT=CERT,
        CASD_CLIENT_KEY=KEY,
    )
    env.pop("BST_CACHE_PUSH_URL", None)
    env.pop("BST_CACHE_PULL_URL", None)
    return tree, env, tmp_path / "log"


def run_push(tree, env, log):
    result = subprocess.run(["bash", str(tree / "scripts" / "bst-cache-push.sh")], env=env, capture_output=True, text=True)
    calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
    return result, calls


def test_push_uploads_only_unpublished_allow_listed_artifacts(push_env):
    tree, env, log = push_env
    result, calls = run_push(tree, env, log)
    assert result.returncode == 0, result.stderr
    push = [c for c in calls if c["args"][:2] == ["artifact", "push"]]
    assert len(push) == 1
    assert push[0]["args"] == ["artifact", "push", "--deps", "none", MODULE_CERT, KERNEL]


def test_push_config_is_only_given_to_the_push(push_env):
    tree, env, log = push_env
    _, calls = run_push(tree, env, log)
    for call in calls:
        is_push = call["args"][:2] == ["artifact", "push"]
        assert ("push: true" in call["config"]) == is_push, call["args"][:2]
        assert ("client.key" in call["config"]) == is_push
    config = yaml.safe_load(next(c["config"] for c in calls if c["args"][:2] == ["artifact", "push"]))
    assert set(config) == {"projects"}
    assert set(config["projects"]) == {"bluefin-server", "freedesktop-sdk"}
    for project in config["projects"].values():
        (server,) = project["artifacts"]["servers"]
        assert server["url"] == "https://cache.projectbluefin.io:11002"
        assert server["push"] is True
        assert server["auth"] == {"client-key": "/src/.bst-cache-push/client.key", "client-cert": "/src/.bst-cache-push/client.crt"}


def test_probe_uses_an_empty_cache_and_the_pull_endpoint(push_env):
    tree, env, log = push_env
    _, calls = run_push(tree, env, log)
    (probe,) = [c for c in calls if c["args"][:2] == ["artifact", "show"]]
    config = yaml.safe_load(probe["config"])
    assert config["cachedir"].startswith("/src/.bst-cache-push/")
    assert [s["url"] for s in config["artifacts"]["servers"]] == ["https://cache.projectbluefin.io:11001"]
    assert KEYS not in probe["args"] and KERNEL_MODULES not in probe["args"]


def test_credentials_are_private_and_removed(push_env):
    tree, env, log = push_env
    result, calls = run_push(tree, env, log)
    assert result.returncode == 0
    assert calls
    for call in calls:
        assert call["files"]["client.crt"] == call["files"]["client.key"] == "0o600"
    assert not (tree / ".bst-cache-push").exists()


def test_failed_push_fails_the_script_and_still_removes_credentials(push_env):
    tree, env, log = push_env
    result, _ = run_push(tree, dict(env, FAKE_PUSH_RC="1"), log)
    assert result.returncode != 0
    assert not (tree / ".bst-cache-push").exists()


def test_nothing_unpublished_means_no_push(push_env):
    tree, env, log = push_env
    result, calls = run_push(tree, dict(env, FAKE_UNPUBLISHED=""), log)
    assert result.returncode == 0
    assert not [c for c in calls if c["args"][:2] == ["artifact", "push"]]


def test_missing_credentials_refuse_to_run(push_env):
    tree, env, log = push_env
    result, calls = run_push(tree, dict(env, CASD_CLIENT_KEY=""), log)
    assert result.returncode != 0
    assert calls == []


def test_push_script_is_shellcheck_clean(shellcheck: str) -> None:
    subprocess.run([shellcheck, "-S", "style", str(PUSH_SCRIPT)], check=True)
