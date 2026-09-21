#!/usr/bin/env python3
"""
check_updates.py — SSoT manifest generator + RSS update checker
Merges generate_manifest.py and update_checker.py into a single script.

stdout: structured JSON for n8n
stderr: operational warnings (services missing from the metadata, etc.)
Exit code: always 0, so n8n never sees a crash

Output shape:
{
  "manifest":             [...],  # Every service — for the Postgres upsert
  "updates":              [...],  # Tracked services with a newer version available
  "errors":               [...],  # Tracked services that hit an RSS/network error
  "unchanged":            [...],  # Tracked services with nothing new
  "untracked_warnings":   [...],  # Services absent from services_metadata.json
  "run_at":               "...",  # ISO 8601 timestamp of this run
  "summary":              {...}   # Aggregate counters, used for routing in n8n
}
"""

import json
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from urllib.parse import urlparse

try:
    import requests
except ImportError:
    print(json.dumps({
        "fatal": "The 'requests' library is not installed. Run: pip install requests",
        "manifest": [], "updates": [], "errors": [],
        "unchanged": [], "untracked_warnings": [],
        "run_at": datetime.now(timezone.utc).isoformat(),
        "summary": {}
    }))
    sys.exit(0)


# ── Configuration ─────────────────────────────────────────────────────────────

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
BASE_DIR    = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
METADATA_PATH = os.path.join(BASE_DIR, "services_metadata.json")

TIMEOUT     = 10    # seconds per HTTP request
THROTTLE    = 1.5   # seconds between RSS requests (GitHub rate limit)

HTTP_HEADERS = {
    "User-Agent": "Homelab-Update-Checker/1.0",
    "Accept":     "application/atom+xml, application/rss+xml, text/xml"
}

UNSTABLE_KEYWORDS = ("alpha", "beta", "rc", "test", "dev", "nightly", "preview")

# The keywords must be matched as version MARKERS, not as substrings.
# A plain `"rc" in title` hits "architecture", "source", "search" and "force";
# "dev" hits "device" and "developer"; "test" hits "latest" and "greatest".
# On a forge that titles releases with a sentence rather than a bare number,
# that match made valid releases disappear — and the checker did not report an
# error, it reported "no updates".
#
# Here a keyword must start where there is no letter (start of string, `-`,
# `.`, a space, or a digit as in "1.0.0rc1") and must not continue into more
# letters: "-rc.1" and "1.0.0rc1" match, "architecture" and "device" do not.
UNSTABLE_RE = re.compile(
    r"(?:^|[^a-z])(?:" + "|".join(UNSTABLE_KEYWORDS) + r")(?![a-z])",
    re.IGNORECASE,
)

# ── Forge API registry ────────────────────────────────────────────────────────
# Each forge has: a host to match, a URL template for the releases API, its
# own headers, and query parameters for pagination.
# Order matters: the first match wins.
# Gitea/Forgejo instances not listed here fall back to GITEA_FALLBACK.

FORGE_REGISTRY = [
    {
        "host":    "github.com",
        "api_tpl": "https://api.github.com/repos/{owner}/{repo}/releases",
        "headers": {
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        "params":  {"per_page": 30},
        "timeout": 10,
    },
    {
        "host":    "codeberg.org",
        "api_tpl": "https://codeberg.org/api/v1/repos/{owner}/{repo}/releases",
        "headers": {"Accept": "application/json"},
        "params":  {"limit": 30},
        "timeout": 30,
    },
    # Add further Gitea/Forgejo/GitLab instances here as needed:
    # {
    #     "host":    "gitea.example.com",
    #     "api_tpl": "https://gitea.example.com/api/v1/repos/{owner}/{repo}/releases",
    #     "headers": {"Accept": "application/json"},
    #     "params":  {"limit": 30},
    # },
]

# Generic fallback for any Gitea/Forgejo instance absent from the registry
GITEA_FALLBACK = {
    "api_tpl": "{scheme}://{netloc}/api/v1/repos/{owner}/{repo}/releases",
    "headers": {"Accept": "application/json"},
    "params":  {"limit": 30},
}

# Extracts Major.Minor.Patch from any version string
SEMVER_RE = re.compile(r"(\d+)\.(\d+)(?:\.(\d+))?")


# ── I/O helpers ───────────────────────────────────────────────────────────────

def load_metadata() -> dict:
    """Load services_metadata.json. Returns {} when the file is absent."""
    if not os.path.exists(METADATA_PATH):
        print(f"⚠️  Metadata file missing: {METADATA_PATH}", file=sys.stderr)
        return {}
    with open(METADATA_PATH, encoding="utf-8") as f:
        return json.load(f)


def run_compose_config() -> dict:
    """
    Runs 'docker compose config --format json'.
    Returns the services dictionary.
    """
    result = subprocess.run(
        ["docker", "compose", "config", "--format", "json"],
        cwd=BASE_DIR,
        capture_output=True,
        text=True,
        check=True
    )
    return json.loads(result.stdout)


# ── Parsing versioni ──────────────────────────────────────────────────────────

def parse_image(full_image: str) -> tuple:
    """
    Splits image and tag on the last ':'.
    Returns (image_name, raw_version, clean_version).

    Examples:
      "nextcloud:33.0.2-apache"  → ("nextcloud", "33.0.2-apache", "33.0.2")
      "postgres:16-alpine"       → ("postgres", "16-alpine", "16")
      "immich-server:v2.7.5-cuda"→ ("immich-server", "v2.7.5-cuda", "v2.7.5")
      "cloudflared:latest"       → ("cloudflared", "latest", "latest")
    """
    if ":" in full_image and not full_image.endswith(":"):
        image_name, raw_version = full_image.rsplit(":", 1)
    else:
        image_name   = full_image
        raw_version  = "latest"

    # Strip build suffixes only when they contain letters
    # "33.0.2-apache" → "33.0.2"  |  "16-alpine" → "16"
    # "9-alpine"      → "9"        |  "2025.01.20" → "2025.01.20" (no suffix)
    parts  = raw_version.split("-")
    suffix = "-".join(parts[1:])
    clean_version = parts[0] if (len(parts) > 1 and any(c.isalpha() for c in suffix)) \
                             else raw_version

    return image_name, raw_version, clean_version


def extract_semver(version_str: str) -> tuple:
    """
    Extracts (major, minor, patch) from a version string.
    Returns (0, 0, 0) when the string holds no usable numbers.

    Handles:
      "10"        → (10, 0, 0)   # single-number Docker tag
      "v15.0.3"   → (15, 0, 3)
      "2.15.0"    → (2, 15, 0)
    """
    if not version_str or version_str == "latest":
        return (0, 0, 0)
    m = SEMVER_RE.search(version_str)
    if m:
        return (
            int(m.group(1)),
            int(m.group(2)),
            int(m.group(3)) if m.group(3) else 0
        )
    # Fallback: single-number version (e.g. Docker tags "10", "8")
    single = re.match(r"v?(\d+)$", version_str.strip())
    if single:
        return (int(single.group(1)), 0, 0)
    return (0, 0, 0)


def determine_bump(current: tuple, latest: tuple) -> tuple:
    """
    Compares two semver tuples.
    Returns (bump_type, is_major_bump).
    bump_type: "major" | "minor" | "patch" | "none" | "unknown"
    """
    if current == (0, 0, 0) or latest == (0, 0, 0):
        return "unknown", False

    c_maj, c_min, c_pat = current
    l_maj, l_min, l_pat = latest

    if l_maj > c_maj:
        return "major", True
    if l_maj == c_maj and l_min > c_min:
        return "minor", False
    if l_maj == c_maj and l_min == c_min and l_pat > c_pat:
        return "patch", False
    return "none", False


# ── Build manifest ────────────────────────────────────────────────────────────

def discover_dependencies(services: dict) -> set:
    """
    Scans every service's depends_on block and returns the set of names
    declared as dependencies.
    """
    deps = set()
    for s_data in services.values():
        declared = s_data.get("depends_on", {})
        if isinstance(declared, dict):
            deps.update(declared.keys())
        elif isinstance(declared, list):
            deps.update(declared)
    return deps


def build_manifest(services: dict, metadata_map: dict) -> tuple:
    """
    Builds the full manifest of every Docker service.
    Returns (manifest: list, untracked_warnings: list).

    Each manifest entry has this shape:
    {
      compose_name, service_name, display_name,
      image_name, raw_version, current_version, full_image,
      is_tracked, criticality, stack_name,
      github_owner, github_repo_name, github_repo_url, rss_url
    }
    """
    discovered_deps    = discover_dependencies(services)
    manifest           = []
    untracked_warnings = []

    for s_name, s_data in services.items():
        full_image = s_data.get("image", "")
        if not full_image:
            continue

        image_name, raw_version, clean_version = parse_image(full_image)

        item = {
            "compose_name":    s_name,
            "service_name":    s_name,
            "display_name":    s_name[0].upper() + s_name[1:] if s_name else "",
            "image_name":      image_name,
            "raw_version":     raw_version,
            "current_version": clean_version,
            "full_image":      full_image,
        }

        meta = metadata_map.get(s_name)

        if meta:
            # ── Service present in services_metadata.json ───────────────────
            stack_name  = meta.get("stack", "unknown")
            criticality = meta.get("criticality", "low")

            display_name = meta.get("display_name") or s_name.replace("-", " ").title()

            if meta.get("repo"):
                # Standard GitHub-hosted service
                owner, repo_name = meta["repo"].split("/", 1)
                item.update({
                    "github_owner":     owner,
                    "github_repo_name": repo_name,
                    "github_repo_url":  f"https://github.com/{meta['repo']}",
                    "rss_url":          f"https://github.com/{meta['repo']}/releases.atom",
                    "criticality":      criticality,
                    "stack_name":       stack_name,
                    "display_name":     display_name,
                    "is_tracked":       True,
                })
            else:
                # Non-GitHub with a direct RSS feed (Forgejo, Gitea, ...)
                # Without rss_url it is known but cannot be tracked
                has_rss = bool(meta.get("rss_url"))
                item.update({
                    "github_owner":     meta.get("github_owner"),
                    "github_repo_name": meta.get("github_repo_name"),
                    "github_repo_url":  meta.get("github_repo_url"),
                    "rss_url":          meta.get("rss_url"),
                    "criticality":      criticality,
                    "stack_name":       stack_name,
                    "display_name":     display_name,
                    "is_tracked":       has_rss,
                })

        elif s_name in discovered_deps:
            # ── Dipendenza rilevata automaticamente (postgres, redis, ecc.) ─
            item.update({
                "github_owner":     None,
                "github_repo_name": None,
                "github_repo_url":  None,
                "rss_url":          None,
                "criticality":      "dependency",
                "stack_name":       "dependency",
                "display_name":     display_name,
                "is_tracked":       False,
            })

        else:
            # ── Unknown service: not in the metadata and not a dependency ───
            # Most likely a missing entry in services_metadata.json
            untracked_warnings.append(s_name)
            print(
                f"⚠️  Warning: '{s_name}' is absent from services_metadata.json "
                f"and appears in no depends_on. Add it to the metadata file.",
                file=sys.stderr
            )
            item.update({
                "github_owner":     None,
                "github_repo_name": None,
                "github_repo_url":  None,
                "rss_url":          None,
                "criticality":      "low",
                "stack_name":       "untracked",
                "display_name":     display_name,
                "is_tracked":       False,
            })

        manifest.append(item)

    return manifest, untracked_warnings


# ── Forge API + RSS check ─────────────────────────────────────────────────────

def _resolve_forge(repo_url: str) -> dict:
    """
    Given a repository URL, returns the API pattern to use.
    Looks up FORGE_REGISTRY by exact host; failing that, it builds
    un endpoint Gitea/Forgejo generico dal dominio (fallback universale).
    """
    parsed = urlparse(repo_url)
    host   = parsed.netloc.lower()

    for entry in FORGE_REGISTRY:
        if entry["host"] == host:
            return entry

    # Fallback: any unknown host is assumed to expose a Gitea/Forgejo API
    return {
        "host":    host,
        "api_tpl": GITEA_FALLBACK["api_tpl"].format(
            scheme=parsed.scheme, netloc=parsed.netloc,
            owner="{owner}", repo="{repo}"
        ),
        "headers": GITEA_FALLBACK["headers"],
        "params":  GITEA_FALLBACK["params"],
    }


def get_latest_from_forge_api(repo_url: str, owner: str, repo: str,
                               current_version: str = "") -> dict:
    """
    Detects the forge from the URL and queries its releases API.
    Supports GitHub, Gitea/Forgejo (Codeberg), and any forge with a
    Gitea-compatible API. The registry is extensible without touching code.

    Returns a dict:
      {"version": "...", "is_prerelease": False, "release_label": "stable",
       "forge": "github.com"|"codeberg.org"|...}

    Raises if no stable release is found or the network fails.
    """
    forge  = _resolve_forge(repo_url)
    url    = forge["api_tpl"].format(owner=owner, repo=repo)
    headers = {**forge["headers"], "User-Agent": "Homelab-Update-Checker/1.0"}

    timeout = forge.get("timeout", TIMEOUT)
    resp = requests.get(url, timeout=timeout, headers=headers,
                        params=forge.get("params", {}))
    resp.raise_for_status()

    releases = resp.json()
    if not isinstance(releases, list):
        raise ValueError(f"Unexpected API response from {forge['host']} for {owner}/{repo}")

    current_semver = extract_semver(current_version)
    current_major  = current_semver[0] if current_semver != (0, 0, 0) else None

    same_branch_stable = []
    any_stable         = []

    for rel in releases:
        if rel.get("draft", False):
            continue

        tag  = rel.get("tag_name", "")
        pre  = rel.get("prerelease", False)

        # Two filters: the structured 'prerelease' field, plus title/tag keywords
        name = rel.get("name", "") or tag
        if pre or not is_stable_release(name) or not is_stable_release(tag):
            continue

        any_stable.append(tag)

        if current_major is not None:
            entry_semver = extract_semver(tag)
            if entry_semver != (0, 0, 0) and entry_semver[0] == current_major:
                same_branch_stable.append(tag)

    # The HIGHEST release, not the first one the API returns.
    # Forges order /releases by tag creation date, which for two releases
    # published on the same day can invert version order: on 2026-09-21 GitHub
    # listed n8n 2.39.9 before 2.39.10, and taking element [0] proposed a
    # version that had already been superseded. Sorting by semver makes the
    # choice deterministic and independent of the forge.
    candidates = same_branch_stable or any_stable
    chosen = max(candidates, key=extract_semver) if candidates else None
    if chosen is None:
        raise ValueError(
            f"No stable release found via the {forge['host']} API for {owner}/{repo}"
        )

    return {
        "version":       chosen,
        "is_prerelease": False,
        "release_label": "stable",
        "forge":         forge["host"],
    }


def is_stable_release(title: str) -> bool:
    """
    True when the title carries no pre-release marker.

    This is a supporting heuristic: the primary defence remains the API's
    boolean `prerelease` field, which `get_latest_from_forge_api` checks
    first. This matters for RSS feeds, where that field does not exist.
    """
    return not UNSTABLE_RE.search(title or "")


def get_latest_from_rss(url: str, current_version: str = "") -> str:
    """
    Fetches the Atom/RSS feed and returns the highest stable release title.
    When current_version is given, a release on the same major is preferred
    BEFORE accepting any release at all (multi-branch forges, e.g. n8n v1/v2).
    Raises if nothing is found or the network fails.
    """
    resp = requests.get(url, timeout=TIMEOUT, headers=HTTP_HEADERS)
    resp.raise_for_status()

    # Drop the default XML namespace to keep the ElementTree queries simple
    xml_clean = re.sub(r'\sxmlns="[^"]+"', "", resp.text, count=1)
    root = ET.fromstring(xml_clean)

    current_semver = extract_semver(current_version)
    current_major  = current_semver[0] if current_semver != (0, 0, 0) else None

    same_branch = []
    any_stable  = []

    for entry in root.findall(".//entry"):
        title_el = entry.find("title")
        if title_el is not None and title_el.text:
            title = title_el.text.strip()
            if not is_stable_release(title):
                continue

            any_stable.append(title)

            # When the current major is known, filter by branch
            if current_major is not None:
                entry_semver = extract_semver(title)
                if entry_semver != (0, 0, 0) and entry_semver[0] == current_major:
                    same_branch.append(title)

    # Preference: same branch > any stable release.
    # As on the API path, take the highest semver rather than the feed's first
    # entry: the order of an Atom feed reflects dates, not versions.
    candidates = same_branch or any_stable
    if candidates:
        return max(candidates, key=extract_semver)

    raise ValueError("No stable release found in the feed")


def check_updates(tracked_services: list) -> tuple:
    """
    Checks releases for tracked services (is_tracked=True and rss_url set).
    Prefers the forge API (GitHub, Codeberg, Gitea...), falling back to RSS.
    Returns (updates, errors, unchanged).

    Each entry is enriched with:
      latest_version, bump_type, is_major_bump, has_update, checked_at,
      is_prerelease, release_label ("stable"|"unverified"|"unknown"),
      source_method ("forge_api"|"rss")
    oppure:
      error_detail, checked_at     (on failure)
    """
    updates   = []
    errors    = []
    unchanged = []
    now_iso   = datetime.now(timezone.utc).isoformat()

    for svc in tracked_services:
        rss_url         = svc.get("rss_url")
        current_version = svc.get("current_version", "")
        criticality     = svc.get("criticality", "low")
        gh_owner        = svc.get("github_owner")
        gh_repo         = svc.get("github_repo_name")
        repo_url        = svc.get("github_repo_url", "")

        result = {**svc, "checked_at": now_iso}

        # ── Stateless services (latest) — no version check needed ──
        if not rss_url or current_version == "latest":
            result["skip_reason"] = "stateless, or no rss_url"
            result.update({"is_prerelease": False, "release_label": "unknown"})
            unchanged.append(result)
            continue

        # ── Throttling ────────────────────────────────────────────────────
        time.sleep(THROTTLE)

        try:
            latest_raw    = None
            is_prerelease = False
            release_label = "unknown"
            source_method = "rss"
            api_error_msg = None

            # ── Prima linea: Forge API (GitHub, Codeberg, Gitea...) ─────────
            if gh_owner and gh_repo and repo_url:
                try:
                    api_result    = get_latest_from_forge_api(
                        repo_url, gh_owner, gh_repo, current_version
                    )
                    latest_raw    = api_result["version"]
                    is_prerelease = api_result["is_prerelease"]
                    release_label = api_result["release_label"]
                    source_method = "forge_api"
                except Exception as api_err:
                    api_error_msg = f"{type(api_err).__name__}: {api_err}"
                    print(
                        f"⚠️  Forge API fallback for {svc.get('display_name', svc.get('compose_name'))}: "
                        f"{api_error_msg}",
                        file=sys.stderr
                    )

            # ── Fallback: RSS (when the forge API failed or is unavailable) ──
            if latest_raw is None:
                latest_raw    = get_latest_from_rss(rss_url, current_version)
                is_prerelease = False          # RSS cannot tell: assume stable
                release_label = "unverified"   # Flags that the API did not confirm it
                source_method = "rss"

            curr_tuple              = extract_semver(current_version)
            lat_tuple               = extract_semver(latest_raw)
            bump_type, is_major     = determine_bump(curr_tuple, lat_tuple)

            # Version distance, used to weight priority
            version_gap = 0
            if curr_tuple != (0, 0, 0) and lat_tuple != (0, 0, 0):
                version_gap = (
                    abs(lat_tuple[0] - curr_tuple[0]) * 100
                    + abs(lat_tuple[1] - curr_tuple[1]) * 10
                    + abs(lat_tuple[2] - curr_tuple[2])
                )

            result.update({
                "latest_version": latest_raw,
                "bump_type":      bump_type,
                "is_major_bump":  is_major,
                "has_update":     bump_type in ("major", "minor", "patch"),
                "version_gap":    version_gap,
                "is_prerelease":  is_prerelease,
                "release_label":  release_label,
                "source_method":  source_method,
            })

            if result["has_update"]:
                updates.append(result)
            else:
                unchanged.append(result)

        except requests.exceptions.HTTPError as e:
            detail = f"HTTP {e.response.status_code} — {rss_url}"
            if api_error_msg:
                detail = f"Forge API: {api_error_msg} → RSS fallback: {detail}"
            result["error_detail"] = detail
            errors.append(result)

        except requests.exceptions.ConnectionError:
            detail = f"Connection refused or DNS failure — {rss_url}"
            if api_error_msg:
                detail = f"Forge API: {api_error_msg} → RSS fallback: {detail}"
            result["error_detail"] = detail
            errors.append(result)

        except requests.exceptions.Timeout:
            detail = f"Timed out after {TIMEOUT}s — {rss_url}"
            if api_error_msg:
                detail = f"Forge API: {api_error_msg} → RSS fallback: {detail}"
            result["error_detail"] = detail
            errors.append(result)

        except ET.ParseError:
            detail = f"Invalid XML feed — {rss_url}"
            if api_error_msg:
                detail = f"Forge API: {api_error_msg} → RSS fallback: {detail}"
            result["error_detail"] = detail
            errors.append(result)

        except ValueError as e:
            detail = str(e)
            if api_error_msg:
                detail = f"Forge API: {api_error_msg} → RSS fallback: {detail}"
            result["error_detail"] = detail
            errors.append(result)

        except Exception as e:
            detail = f"Unexpected error: {type(e).__name__}: {e}"
            if api_error_msg:
                detail = f"Forge API: {api_error_msg} → RSS fallback: {detail}"
            result["error_detail"] = detail
            errors.append(result)

    return updates, errors, unchanged


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    run_at = datetime.now(timezone.utc).isoformat()

    try:
        # 1. Load the metadata and the compose configuration
        metadata_map  = load_metadata()
        compose_data  = run_compose_config()
        services      = compose_data.get("services", {})

        if not services:
            print(json.dumps({
                "manifest": [], "updates": [], "errors": [],
                "unchanged": [], "untracked_warnings": [],
                "run_at": run_at,
                "summary": {
                    "total": 0, "tracked": 0, "updates_found": 0,
                    "errors": 0, "unchanged": 0, "untracked": 0
                }
            }))
            return

        # 2. Build the manifest for EVERY service (Postgres upsert)
        manifest, untracked_warnings = build_manifest(services, metadata_map)

        # 3. Check releases only for tracked services that have a feed
        tracked = [s for s in manifest if s.get("is_tracked") and s.get("rss_url")]
        updates, errors, unchanged = check_updates(tracked)

        # 4. Structured output for n8n
        output = {
            "manifest":           manifest,
            "updates":            updates,
            "errors":             errors,
            "unchanged":          unchanged,
            "untracked_warnings": untracked_warnings,
            "run_at":             run_at,
            "summary": {
                "total":          len(manifest),
                "tracked":        len(tracked),
                "updates_found":  len(updates),
                "errors":         len(errors),
                "unchanged":      len(unchanged),
                "untracked":      len(untracked_warnings),
                "has_fatal":      False,
            }
        }

        print(json.dumps(output, ensure_ascii=False))

    except subprocess.CalledProcessError as e:
        # `docker compose config` itself failed: without it there is no
        # manifest to build, so this is fatal rather than a per-service error.
        print(json.dumps({
            "fatal":              f"docker compose config failed: {e.stderr.strip()}",
            "manifest":           [], "updates": [], "errors": [],
            "unchanged":          [], "untracked_warnings": [],
            "run_at":             run_at,
            "summary":            {"has_fatal": True}
        }))

    except json.JSONDecodeError as e:
        print(json.dumps({
            "fatal":              f"docker compose output is not valid JSON: {e}",
            "manifest":           [], "updates": [], "errors": [],
            "unchanged":          [], "untracked_warnings": [],
            "run_at":             run_at,
            "summary":            {"has_fatal": True}
        }))

    except Exception as e:
        print(json.dumps({
            "fatal":              f"Unexpected error: {type(e).__name__}: {e}",
            "manifest":           [], "updates": [], "errors": [],
            "unchanged":          [], "untracked_warnings": [],
            "run_at":             run_at,
            "summary":            {"has_fatal": True}
        }))


if __name__ == "__main__":
    main()
