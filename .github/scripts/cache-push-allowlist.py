#!/usr/bin/env python3
"""Decide which BuildStream artifacts main may upload to the shared cache.

`bst artifact push` uploads whatever it is given, and a push remote that is
configured during `bst build` uploads everything the build produces, including
`bluefin-server/keys/boot-keys.bst`, whose artifact holds the release signing
keys. .github/scripts/bst-cache-push.sh therefore only ever pushes an explicit
element list, computed here from the element graph:

    format       print the `bst show --format` string this script parses
    allowlist    graph on stdin -> elements that may be uploaded
    projects     graph on stdin -> BuildStream project names owning those elements
    unpublished  `bst artifact show` output on stdin -> elements no remote has

An element is left out, together with every element that build- or
runtime-depends on it (directly or transitively), when:

  - it is `bluefin-server/keys/boot-keys.bst`;
  - one of its local sources is, contains, or lies under a secret path
    (`files/boot-keys`), or names `boot-keys` at all. The one exception is
    `files/boot-keys/modules`, which `gen-dev-keys.sh` and build.yml keep to
    the public module certificate that every shipped kernel embeds anyway;
    it is only exempt while every file there is a PEM certificate with no
    private key block, so FSDK's kernel, which build-depends on
    `bluefin-server/keys/linux-module-cert.bst`, stays uploadable;
  - it includes `include/image.yml` (it has the `image-version` variable):
    its cache key changes on every build, so uploading it is cache churn;
  - it is a junction, which has no artifact.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

import yaml

KEYS_ELEMENT = "bluefin-server/keys/boot-keys.bst"
SECRET_PATHS = ("files/boot-keys",)
# Public-only subpaths of SECRET_PATHS, exempt only after check_public_dir().
PUBLIC_PATHS = ("files/boot-keys/modules",)
VERSION_VARIABLE = "image-version"

FIELDS = ("name", "kind", "state", "build-deps", "runtime-deps", "source-info", "vars")
MARKER = "#@"
# One marker line per field; the multi-line YAML dumps of the list and mapping
# fields follow their marker, so each field is parsed on its own.
BST_FORMAT = "\n".join(f"{MARKER}{f} %{{{f}}}" for f in FIELDS)

ANSI = re.compile(r"\x1b\[[0-9;]*m")
PEM_BLOCK = re.compile(r"-----BEGIN ([A-Z0-9 ]+)-----")


@dataclass
class Element:
    name: str
    kind: str = ""
    state: str = ""
    build_deps: list[str] = field(default_factory=list)
    runtime_deps: list[str] = field(default_factory=list)
    local_paths: list[str] = field(default_factory=list)
    project: str = ""
    version_stamped: bool = False


def _load(text: str):
    text = text.strip()
    return yaml.safe_load(text) if text else None


def parse_graph(text: str) -> dict[str, Element]:
    """Parse `bst show --format BST_FORMAT` output into elements by name."""
    records: list[dict[str, list[str]]] = []
    current: dict[str, list[str]] | None = None
    key = ""
    for line in ANSI.sub("", text).splitlines():
        if line.startswith(MARKER):
            head, _, rest = line[len(MARKER):].partition(" ")
            if head in FIELDS:
                if head == "name":
                    current = {}
                    records.append(current)
                if current is None:
                    raise ValueError(f"field {head!r} before any element name")
                key = head
                current[key] = [rest]
                continue
        if current is not None and key:
            current[key].append(line)

    elements: dict[str, Element] = {}
    for record in records:
        missing = [f for f in FIELDS if f not in record]
        if missing:
            raise ValueError(f"element record without {missing}: {record.get('name')}")
        name = "\n".join(record["name"]).strip()
        variables = _load("\n".join(record["vars"])) or {}
        sources = _load("\n".join(record["source-info"])) or []
        elements[name] = Element(
            name=name,
            kind="\n".join(record["kind"]).strip(),
            state="\n".join(record["state"]).strip(),
            build_deps=list(_load("\n".join(record["build-deps"])) or []),
            runtime_deps=list(_load("\n".join(record["runtime-deps"])) or []),
            local_paths=[str(s.get("url", "")) for s in sources if s.get("medium") == "local"],
            project=str(variables.get("project-name", "")),
            version_stamped=VERSION_VARIABLE in variables,
        )
    if not elements:
        raise ValueError("no elements in the graph; was it produced with `format`?")
    return elements


def check_public_dir(directory: Path) -> bool:
    """True if every file under `directory` is a PEM certificate and nothing else."""
    if not directory.is_dir():
        return False
    files = [p for p in directory.rglob("*") if not p.is_dir()]
    if not files:
        return False
    for path in files:
        if path.is_symlink() or not path.is_file():
            return False
        text = path.read_text(encoding="ascii", errors="replace")
        blocks = PEM_BLOCK.findall(text)
        if not blocks or any(b != "CERTIFICATE" for b in blocks) or "PRIVATE" in text:
            return False
    return True


def _norm(path: str) -> str:
    return path.strip().rstrip("/").removeprefix("./") or "."


def _overlaps(path: str, other: str) -> bool:
    return path == "." or path == other or path.startswith(other + "/") or other.startswith(path + "/")


def secret_reason(element: Element, public_paths: tuple[str, ...]) -> str | None:
    if element.name == KEYS_ELEMENT:
        return "boot-keys element"
    for raw in element.local_paths:
        path = _norm(raw)
        if any(path == p or path.startswith(p + "/") for p in public_paths):
            continue
        if any(_overlaps(path, s) for s in SECRET_PATHS) or "boot-keys" in path:
            return f"local source {raw}"
    return None


def exclusions(elements: dict[str, Element], public_paths: tuple[str, ...]) -> dict[str, str]:
    excluded: dict[str, str] = {}
    for element in elements.values():
        reason = secret_reason(element, public_paths)
        if reason:
            excluded[element.name] = f"secret: {reason}"
        elif element.version_stamped:
            excluded[element.name] = "version-stamped (include/image.yml)"
        elif element.kind == "junction":
            excluded[element.name] = "junction"

    dependents: dict[str, set[str]] = {}
    for element in elements.values():
        for dep in element.build_deps + element.runtime_deps:
            dependents.setdefault(dep, set()).add(element.name)

    queue = list(excluded)
    while queue:
        name = queue.pop()
        for dependent in sorted(dependents.get(name, ())):
            if dependent not in excluded:
                excluded[dependent] = f"depends on {name}"
                queue.append(dependent)
    return excluded


def allowlist(elements: dict[str, Element], repo_root: Path) -> tuple[list[str], dict[str, str]]:
    public = tuple(p for p in PUBLIC_PATHS if check_public_dir(repo_root / p))
    excluded = exclusions(elements, public)
    return [name for name in elements if name not in excluded], excluded


def parse_artifact_show(text: str) -> dict[str, str]:
    """`bst artifact show` lines ("cached  foo.bst", "not cached  foo.bst")."""
    states: dict[str, str] = {}
    for line in ANSI.sub("", text).splitlines():
        match = re.match(r"^\s*(cached|available|not cached|failed)\s+(\S+)\s*$", line)
        if match:
            states[match.group(2)] = match.group(1)
    return states


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("format", help="print the bst show --format string")
    for command in ("allowlist", "projects"):
        p = sub.add_parser(command)
        p.add_argument("--repo-root", type=Path, default=Path("."), help="checkout holding files/boot-keys")
        p.add_argument("--cached-only", action="store_true", help="only elements cached locally")
        p.add_argument("--explain", action="store_true", help="print every exclusion to stderr")
    sub.add_parser("unpublished")
    args = parser.parse_args(argv)

    if args.command == "format":
        print(BST_FORMAT)
        return 0
    if args.command == "unpublished":
        states = parse_artifact_show(sys.stdin.read())
        for name, state in states.items():
            if state == "not cached":
                print(name)
        return 0

    elements = parse_graph(sys.stdin.read())
    names, excluded = allowlist(elements, args.repo_root)
    if args.cached_only:
        names = [n for n in names if elements[n].state == "cached"]
    if args.explain:
        for name, reason in excluded.items():
            print(f"excluded {name}: {reason}", file=sys.stderr)
    if args.command == "projects":
        for project in sorted({elements[n].project for n in names if elements[n].project}):
            print(project)
    else:
        for name in names:
            print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
