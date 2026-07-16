#!/usr/bin/env python3
"""Validate SwiftCodexCore's pinned OpenAI Codex compatibility contracts."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path, PurePosixPath
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = ROOT / "UpstreamParity" / "codex.json"
USER_AGENT = "SwiftCodexCore-upstream-parity/1"


class ParityError(RuntimeError):
    """A pinned upstream contract is invalid or has drifted."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        type=Path,
        default=DEFAULT_MANIFEST,
        help=f"parity manifest to validate (default: {DEFAULT_MANIFEST})",
    )
    parser.add_argument(
        "--check-upstream-head",
        action="store_true",
        help="also fail when the tracked upstream branch no longer points at the pin",
    )
    return parser.parse_args()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ParityError(message)


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ParityError(f"cannot read manifest {path}: {error}") from error

    require(manifest.get("schema_version") == 1, "unsupported manifest schema_version")
    upstream = manifest.get("upstream")
    require(isinstance(upstream, dict), "manifest is missing upstream metadata")
    commit = upstream.get("commit", "")
    require(
        isinstance(commit, str) and re.fullmatch(r"[0-9a-f]{40}", commit) is not None,
        "upstream commit must be a full lowercase SHA-1",
    )
    require(
        isinstance(upstream.get("repository"), str), "upstream repository is missing"
    )
    require(isinstance(upstream.get("branch"), str), "upstream branch is missing")

    sources = manifest.get("sources")
    require(
        isinstance(sources, dict) and sources, "manifest must pin at least one source"
    )
    for name, source in sources.items():
        require(isinstance(source, dict), f"source {name!r} must be an object")
        source_path = source.get("path", "")
        parsed_path = (
            PurePosixPath(source_path) if isinstance(source_path, str) else None
        )
        require(
            parsed_path is not None
            and not parsed_path.is_absolute()
            and ".." not in parsed_path.parts,
            f"source {name!r} has an unsafe path",
        )
        require(
            isinstance(source.get("sha256"), str)
            and re.fullmatch(r"[0-9a-f]{64}", source["sha256"]) is not None,
            f"source {name!r} must have a lowercase SHA-256",
        )
    return manifest


def github_repository_path(repository: str) -> str:
    parsed = urllib.parse.urlparse(repository)
    require(parsed.scheme == "https", "upstream repository must use HTTPS")
    require(
        parsed.hostname == "github.com",
        "only github.com upstream repositories are supported",
    )
    repository_path = parsed.path.strip("/")
    if repository_path.endswith(".git"):
        repository_path = repository_path[:-4]
    require(
        repository_path.count("/") == 1,
        "upstream repository must identify an owner and repository",
    )
    return repository_path


def download(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read()
    except (urllib.error.URLError, TimeoutError) as error:
        raise ParityError(f"failed to download {url}: {error}") from error


def fetch_pinned_sources(manifest: dict[str, Any]) -> dict[str, bytes]:
    upstream = manifest["upstream"]
    repository_path = github_repository_path(upstream["repository"])
    commit = upstream["commit"]
    fetched: dict[str, bytes] = {}

    for name, source in manifest["sources"].items():
        url = f"https://raw.githubusercontent.com/{repository_path}/{commit}/{source['path']}"
        content = download(url)
        digest = hashlib.sha256(content).hexdigest()
        require(
            digest == source["sha256"],
            f"pinned source {name!r} hash mismatch: expected {source['sha256']}, got {digest}",
        )
        fetched[name] = content
        print(f"OK source {name}: {source['path']} ({digest[:12]})")
    return fetched


def validate_catalog(contract: dict[str, Any], sources: dict[str, bytes]) -> None:
    source_name = contract.get("source")
    require(
        source_name in sources, f"catalog references unknown source {source_name!r}"
    )
    try:
        catalog = json.loads(sources[source_name])
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ParityError(f"catalog source is not valid JSON: {error}") from error

    models = catalog.get("models")
    require(
        isinstance(models, list), "upstream catalog does not contain a models array"
    )
    by_slug = {model.get("slug"): model for model in models if isinstance(model, dict)}
    require(
        len(by_slug) == len(models),
        "upstream catalog contains an invalid or duplicate model slug",
    )

    expected_models = contract.get("models")
    require(
        isinstance(expected_models, list) and expected_models,
        "catalog contract has no models",
    )
    for expected in expected_models:
        slug = expected.get("slug")
        actual = by_slug.get(slug)
        require(actual is not None, f"upstream catalog is missing {slug!r}")
        fields = expected.get("fields")
        require(
            isinstance(fields, dict), f"catalog contract for {slug!r} has no fields"
        )
        for field, expected_value in fields.items():
            require(
                actual.get(field) == expected_value,
                f"{slug}.{field} drifted: expected {expected_value!r}, got {actual.get(field)!r}",
            )

        actual_efforts = [
            effort.get("effort")
            for effort in actual.get("supported_reasoning_levels", [])
            if isinstance(effort, dict)
        ]
        require(
            actual_efforts == expected.get("reasoning_efforts"),
            f"{slug}.supported_reasoning_levels drifted: "
            f"expected {expected.get('reasoning_efforts')!r}, got {actual_efforts!r}",
        )
        print(f"OK catalog contract: {slug}")


def snake_case(name: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


def rust_block(source: str, declaration: str) -> str:
    match = re.search(
        rf"{re.escape(declaration)}\s*\{{(?P<body>.*?)^\}}",
        source,
        re.MULTILINE | re.DOTALL,
    )
    require(match is not None, f"could not locate {declaration!r} in upstream schema")
    return match.group("body")


def validate_tool_mode(contract: dict[str, Any], sources: dict[str, bytes]) -> None:
    schema_name = contract.get("schema_source")
    dispatch_name = contract.get("dispatch_source")
    require(
        schema_name in sources,
        f"tool-mode contract references unknown source {schema_name!r}",
    )
    require(
        dispatch_name in sources,
        f"tool-mode contract references unknown source {dispatch_name!r}",
    )
    try:
        schema = sources[schema_name].decode("utf-8")
        dispatch = sources[dispatch_name].decode("utf-8")
    except UnicodeDecodeError as error:
        raise ParityError(f"tool-mode source is not UTF-8: {error}") from error

    enum_body = rust_block(schema, "pub enum ToolMode")
    variants = re.findall(r"^\s*([A-Z][A-Za-z0-9_]*)\s*,", enum_body, re.MULTILINE)
    wire_values = [snake_case(variant) for variant in variants]
    require(
        wire_values == contract.get("wire_values"),
        f"ToolMode wire schema drifted: expected {contract.get('wire_values')!r}, got {wire_values!r}",
    )

    model_info_body = rust_block(schema, "pub struct ModelInfo")
    model_info_fields = set(
        re.findall(r"^\s*pub\s+([a-z][a-z0-9_]*)\s*:", model_info_body, re.MULTILINE)
    )
    for field in contract.get("model_info_fields", []):
        require(field in model_info_fields, f"ModelInfo no longer declares {field!r}")

    for snippet in contract.get("dispatch_snippets", []):
        require(
            snippet in dispatch, f"tool-mode dispatch no longer contains {snippet!r}"
        )
    print(f"OK tool-mode schema: {', '.join(wire_values)}")


def validate_raw_response_usage(
    contract: dict[str, Any], sources: dict[str, bytes]
) -> None:
    source_name = contract.get("source")
    require(
        source_name in sources,
        f"raw-response contract references unknown source {source_name!r}",
    )
    try:
        schema = json.loads(sources[source_name])
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ParityError(f"raw-response source is not valid JSON: {error}") from error

    breakdown = schema.get("definitions", {}).get("TokenUsageBreakdown", {})
    properties = breakdown.get("properties")
    require(
        isinstance(properties, dict),
        "raw-response schema has no TokenUsageBreakdown properties",
    )
    expected_fields = contract.get("fields")
    require(
        isinstance(expected_fields, list) and expected_fields,
        "raw-response contract has no usage fields",
    )
    for field in expected_fields:
        require(field in properties, f"raw-response usage no longer declares {field!r}")
    cache_write = properties.get("cacheWriteInputTokens", {})
    require(
        cache_write.get("type") == "integer" and cache_write.get("default") == 0,
        "cacheWriteInputTokens must remain an integer defaulting to zero",
    )
    print(f"OK raw-response usage: {', '.join(expected_fields)}")


def upstream_head(repository: str, branch: str) -> str:
    try:
        result = subprocess.run(
            ["git", "ls-remote", "--exit-code", repository, f"refs/heads/{branch}"],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise ParityError(
            f"cannot resolve upstream branch {branch!r}: {error}"
        ) from error
    fields = result.stdout.split()
    require(
        len(fields) >= 2 and re.fullmatch(r"[0-9a-f]{40}", fields[0]) is not None,
        "invalid git ls-remote response",
    )
    return fields[0]


def main() -> int:
    args = parse_args()
    try:
        manifest = load_manifest(args.manifest.resolve())
        pin = manifest["upstream"]["commit"]
        print(f"OK manifest: OpenAI Codex pin {pin}")
        sources = fetch_pinned_sources(manifest)
        validate_catalog(manifest["contracts"]["model_catalog"], sources)
        validate_tool_mode(manifest["contracts"]["tool_mode"], sources)
        validate_raw_response_usage(
            manifest["contracts"]["raw_response_usage"], sources
        )

        if args.check_upstream_head:
            upstream = manifest["upstream"]
            head = upstream_head(upstream["repository"], upstream["branch"])
            require(
                head == pin,
                f"upstream drift detected: {upstream['branch']} is {head}, parity pin is {pin}",
            )
            print(
                f"OK upstream head: {upstream['branch']} still points at the parity pin"
            )
    except (KeyError, TypeError, ParityError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print("Upstream parity checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
