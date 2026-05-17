#!/usr/bin/env python3
import json
import os
import subprocess
import sys

# 🔍 Rilevamento automatico e dinamico della cartella root
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
BASE_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))

METADATA_PATH = os.path.join(BASE_DIR, "services_metadata.json")

def load_metadata():
    if not os.path.exists(METADATA_PATH):
        print(f"❌ File metadati mancante: {METADATA_PATH}", file=sys.stderr)
        return {}
    with open(METADATA_PATH, "r") as f:
        return json.load(f)

def run_compose_config():
    try:
        result = subprocess.run(
            ["docker", "compose", "--profile", "*", "config", "--format", "json"],
            cwd=BASE_DIR,
            capture_output=True,
            text=True,
            check=True
        )
        return json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        print(f"❌ Errore 'docker compose config': {e.stderr}", file=sys.stderr)
        sys.exit(1)

def main():
    metadata_map = load_metadata()
    compose_config = run_compose_config()
    services = compose_config.get("services", {})

    if not services:
        print(json.dumps([]))
        return

    # 1. Rilevamento automatico delle dipendenze tramite scansione dei blocchi 'depends_on'
    discovered_dependencies = set()
    for s_name, s_data in services.items():
        if "depends_on" in s_data:
            deps = s_data["depends_on"]
            if isinstance(deps, dict):
                discovered_dependencies.update(deps.keys())
            elif isinstance(deps, list):
                discovered_dependencies.update(deps)

    manifest = []

    # 2. Generazione dello schema JSON unificato
    for s_name, s_data in services.items():
        full_image = s_data.get("image")
        if not full_image:
            continue

        # Separazione immagine e tag dell'ultimo ':'
        if ":" in full_image and not full_image.endswith(":"):
            image_name, raw_version = full_image.rsplit(":", 1)
        else:
            image_name = full_image
            raw_version = "latest"

        # Pulizia versione (Equivalente della regex JS usata nel vecchio n8n)
        parts = raw_version.split('-')
        suffix = '-'.join(parts[1:])
        if len(parts) > 1 and any(c.isalpha() for c in suffix):
            current_version = parts[0]
        else:
            current_version = raw_version

        # Struttura dati base del servizio
        item = {
            "compose_name": s_name,
            "image_name": image_name,
            "raw_version": raw_version,
            "current_version": current_version,
            "full_image": full_image,
            "service_name": s_name,
            "display_name": s_name[0].upper() + s_name[1:] if s_name else ""
        }

        meta = metadata_map.get(s_name)

        if meta:
            # Caso A: Servizio tracciato nel file dei metadati
            stack_name = meta.get("stack", "unknown")
            criticality = meta.get("criticality", "low")

            if meta.get("repo"):
                # Servizio GitHub Standard
                owner, repo_name = meta["repo"].split('/')
                item.update({
                    "github_owner": owner,
                    "github_repo_name": repo_name,
                    "github_repo_url": f"https://github.com/{meta['repo']}",
                    "rss_url": f"https://github.com/{meta['repo']}/releases.atom",
                    "criticality": criticality,
                    "stack_name": stack_name,
                    "is_tracked": True
                })
            else:
                # Servizio Custom non-GitHub (Forgejo, Garage, ecc.)
                item.update({
                    "github_owner": meta.get("github_owner"),
                    "github_repo_name": meta.get("github_repo_name"),
                    "github_repo_url": meta.get("github_repo_url"),
                    "rss_url": meta.get("rss_url"),
                    "criticality": criticality,
                    "stack_name": stack_name,
                    "is_tracked": True
                })
        else:
            # Caso B: Servizio non presente nei metadati
            if s_name in discovered_dependencies:
                # È una dipendenza riconosciuta automaticamente (es: n8n-db)
                item.update({
                    "github_owner": None,
                    "github_repo_name": None,
                    "github_repo_url": None,
                    "rss_url": None,
                    "criticality": "dependency",
                    "stack_name": "dependency",
                    "is_tracked": False
                })
            else:
                # È un servizio principale ma ti sei dimenticato di metterlo in services_metadata.json
                print(f"⚠️ Warning: Il servizio '{s_name}' non è censito in services_metadata.json!", file=sys.stderr)
                item.update({
                    "github_owner": None,
                    "github_repo_name": None,
                    "github_repo_url": None,
                    "rss_url": None,
                    "criticality": "low",
                    "stack_name": "untracked",
                    "is_tracked": False
                })

        manifest.append(item)

    # Stampa in stdout il JSON array finale pulito
    print(json.dumps(manifest, indent=2))

if __name__ == "__main__":
    main()
