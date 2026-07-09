#!/usr/bin/env python3
"""
check_updates.py — SSoT manifest generator + RSS update checker
Unifica generate_manifest.py e update_checker.py in un singolo script.

Output stdout: JSON strutturato per n8n
Output stderr: warning operativi (servizi non censiti, ecc.)
Exit code: sempre 0 (n8n non va in crash)

Struttura output:
{
  "manifest":             [...],  # Tutti i servizi — per l'upsert Postgres
  "updates":              [...],  # Servizi tracciati con nuove versioni disponibili
  "errors":               [...],  # Servizi tracciati con errori RSS/rete
  "unchanged":            [...],  # Servizi tracciati senza novità
  "untracked_warnings":   [...],  # Nomi servizi non censiti in services_metadata.json
  "run_at":               "...",  # Timestamp ISO 8601 dell'esecuzione
  "summary":              {...}   # Contatori aggregati per n8n routing
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

try:
    import requests
except ImportError:
    print(json.dumps({
        "fatal": "Libreria 'requests' non installata. Esegui: pip install requests",
        "manifest": [], "updates": [], "errors": [],
        "unchanged": [], "untracked_warnings": [],
        "run_at": datetime.now(timezone.utc).isoformat(),
        "summary": {}
    }))
    sys.exit(0)


# ── Configurazione ────────────────────────────────────────────────────────────

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
BASE_DIR    = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
METADATA_PATH = os.path.join(BASE_DIR, "services_metadata.json")

TIMEOUT     = 10    # secondi per ogni richiesta HTTP
THROTTLE    = 1.5   # secondi tra una richiesta RSS e la successiva (GitHub rate limit)

HTTP_HEADERS = {
    "User-Agent": "Homelab-Update-Checker/1.0",
    "Accept":     "application/atom+xml, application/rss+xml, text/xml"
}

UNSTABLE_KEYWORDS = ("alpha", "beta", "rc", "test", "dev", "nightly", "preview")

# Regex per estrarre Major.Minor.Patch da qualsiasi stringa di versione
SEMVER_RE = re.compile(r"(\d+)\.(\d+)(?:\.(\d+))?")


# ── I/O helpers ───────────────────────────────────────────────────────────────

def load_metadata() -> dict:
    """Carica services_metadata.json. Ritorna {} se il file manca."""
    if not os.path.exists(METADATA_PATH):
        print(f"⚠️  File metadati mancante: {METADATA_PATH}", file=sys.stderr)
        return {}
    with open(METADATA_PATH, encoding="utf-8") as f:
        return json.load(f)


def run_compose_config() -> dict:
    """
    Esegue 'docker compose config --format json'.
    Ritorna il dizionario dei servizi.
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
    Separa immagine e tag dall'ultimo ':'.
    Ritorna (image_name, raw_version, clean_version).

    Esempi:
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

    # Rimuove suffissi build solo se contengono lettere
    # "33.0.2-apache" → "33.0.2"  |  "16-alpine" → "16"
    # "9-alpine"      → "9"        |  "2025.01.20" → "2025.01.20" (nessun suffisso)
    parts  = raw_version.split("-")
    suffix = "-".join(parts[1:])
    clean_version = parts[0] if (len(parts) > 1 and any(c.isalpha() for c in suffix)) \
                             else raw_version

    return image_name, raw_version, clean_version


def extract_semver(version_str: str) -> tuple:
    """
    Estrae (major, minor, patch) da una stringa di versione.
    Ritorna (0, 0, 0) se la stringa non contiene numeri validi.

    Gestisce:
      "10"        → (10, 0, 0)   # tag Docker a singolo numero
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
    # Fallback: versione a singolo numero (es. tag Docker "10", "8")
    single = re.match(r"v?(\d+)$", version_str.strip())
    if single:
        return (int(single.group(1)), 0, 0)
    return (0, 0, 0)


def determine_bump(current: tuple, latest: tuple) -> tuple:
    """
    Confronta due tuple semver.
    Ritorna (bump_type, is_major_bump).
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
    Scansiona i blocchi depends_on di tutti i servizi e ritorna
    un set con i nomi di tutte le dipendenze dichiarate.
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
    Costruisce il manifest completo di tutti i servizi Docker.
    Ritorna (manifest: list, untracked_warnings: list).

    Ogni item del manifest ha questa struttura:
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
            # ── Servizio censito in services_metadata.json ──────────────────
            stack_name  = meta.get("stack", "unknown")
            criticality = meta.get("criticality", "low")

            display_name = meta.get("display_name") or s_name.replace("-", " ").title()

            if meta.get("repo"):
                # Servizio GitHub standard
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
                # Non-GitHub con RSS diretto (Forgejo, Gitea, ecc.)
                # Se manca anche rss_url, è censito ma non tracciabile
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
            # ── Servizio sconosciuto: non censito e non dipendenza ───────────
            # Probabilmente manca una riga in services_metadata.json
            untracked_warnings.append(s_name)
            print(
                f"⚠️  Warning: '{s_name}' non è censito in services_metadata.json "
                f"e non compare in nessun depends_on. Aggiungilo al file metadati.",
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


# ── RSS check ─────────────────────────────────────────────────────────────────

def is_stable_release(title: str) -> bool:
    """True se il titolo della release non contiene keyword di pre-release."""
    return not any(kw in title.lower() for kw in UNSTABLE_KEYWORDS)


def get_latest_from_rss(url: str) -> str:
    """
    Scarica il feed Atom/RSS e ritorna il titolo della prima release stabile.
    Lancia eccezione se non trova nulla o se la rete fallisce.
    """
    resp = requests.get(url, timeout=TIMEOUT, headers=HTTP_HEADERS)
    resp.raise_for_status()

    # Rimuove il namespace XML default per semplificare le query ElementTree
    xml_clean = re.sub(r'\sxmlns="[^"]+"', "", resp.text, count=1)
    root = ET.fromstring(xml_clean)

    for entry in root.findall(".//entry"):
        title_el = entry.find("title")
        if title_el is not None and title_el.text:
            title = title_el.text.strip()
            if is_stable_release(title):
                return title

    raise ValueError("Nessuna release stabile trovata nel feed")


def check_updates(tracked_services: list) -> tuple:
    """
    Controlla gli RSS solo per i servizi tracciati (is_tracked=True e rss_url valorizzato).
    Ritorna (updates, errors, unchanged).

    Ogni item viene arricchito con:
      latest_version, bump_type, is_major_bump, has_update, checked_at
    oppure:
      error_detail, checked_at     (in caso di errore)
    """
    updates   = []
    errors    = []
    unchanged = []
    now_iso   = datetime.now(timezone.utc).isoformat()

    for svc in tracked_services:
        rss_url         = svc.get("rss_url")
        current_version = svc.get("current_version", "")
        criticality     = svc.get("criticality", "low")

        result = {**svc, "checked_at": now_iso}

        # ── Servizi stateless (latest) — nessun check versione necessario ──
        if not rss_url or current_version == "latest":
            result["skip_reason"] = "stateless o rss_url assente"
            unchanged.append(result)
            continue

        # ── Throttling ────────────────────────────────────────────────────
        time.sleep(THROTTLE)

        try:
            latest_raw = get_latest_from_rss(rss_url)

            curr_tuple              = extract_semver(current_version)
            lat_tuple               = extract_semver(latest_raw)
            bump_type, is_major     = determine_bump(curr_tuple, lat_tuple)

            result.update({
                "latest_version": latest_raw,
                "bump_type":      bump_type,
                "is_major_bump":  is_major,
                "has_update":     bump_type in ("major", "minor", "patch"),
            })

            if result["has_update"]:
                updates.append(result)
            else:
                unchanged.append(result)

        except requests.exceptions.HTTPError as e:
            result["error_detail"] = f"HTTP {e.response.status_code} — {rss_url}"
            errors.append(result)

        except requests.exceptions.ConnectionError:
            result["error_detail"] = f"Connessione rifiutata o DNS fallito — {rss_url}"
            errors.append(result)

        except requests.exceptions.Timeout:
            result["error_detail"] = f"Timeout dopo {TIMEOUT}s — {rss_url}"
            errors.append(result)

        except ET.ParseError:
            result["error_detail"] = f"Feed XML non valido — {rss_url}"
            errors.append(result)

        except ValueError as e:
            result["error_detail"] = str(e)
            errors.append(result)

        except Exception as e:
            result["error_detail"] = f"Errore imprevisto: {type(e).__name__}: {e}"
            errors.append(result)

    return updates, errors, unchanged


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    run_at = datetime.now(timezone.utc).isoformat()

    try:
        # 1. Carica metadati e configurazione compose
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

        # 2. Costruisce il manifest per TUTTI i servizi (upsert Postgres)
        manifest, untracked_warnings = build_manifest(services, metadata_map)

        # 3. Controlla RSS solo per i servizi tracciati con un feed valido
        tracked = [s for s in manifest if s.get("is_tracked") and s.get("rss_url")]
        updates, errors, unchanged = check_updates(tracked)

        # 4. Output strutturato per n8n
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
        # docker compose config ha fallito
        print(json.dumps({
            "fatal":              f"docker compose config fallito: {e.stderr.strip()}",
            "manifest":           [], "updates": [], "errors": [],
            "unchanged":          [], "untracked_warnings": [],
            "run_at":             run_at,
            "summary":            {"has_fatal": True}
        }))

    except json.JSONDecodeError as e:
        print(json.dumps({
            "fatal":              f"Output docker compose non è JSON valido: {e}",
            "manifest":           [], "updates": [], "errors": [],
            "unchanged":          [], "untracked_warnings": [],
            "run_at":             run_at,
            "summary":            {"has_fatal": True}
        }))

    except Exception as e:
        print(json.dumps({
            "fatal":              f"Errore imprevisto: {type(e).__name__}: {e}",
            "manifest":           [], "updates": [], "errors": [],
            "unchanged":          [], "untracked_warnings": [],
            "run_at":             run_at,
            "summary":            {"has_fatal": True}
        }))


if __name__ == "__main__":
    main()
