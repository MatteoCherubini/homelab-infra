#!/usr/bin/env python3
import json
import requests
import re
import sys
import time
import xml.etree.ElementTree as ET

TIMEOUT = 10
HEADERS = {
    "User-Agent": "Homelab-Update-Checker/1.0",
    "Accept": "application/atom+xml, application/rss+xml, text/xml"
}

# Regex per estrarre Major.Minor.Patch (es. da "v1.24.3-alpine" estrae 1, 24, 3)
SEMVER_REGEX = re.compile(r'(\d+)\.(\d+)(?:\.(\d+))?')

def is_stable_release(title: str) -> bool:
    """Filtra le release instabili"""
    title_lower = title.lower()
    unstable_keywords = ['alpha', 'beta', 'rc', 'test', 'dev', 'nightly']
    return not any(keyword in title_lower for keyword in unstable_keywords)

def extract_semver(version_str: str):
    """Estrae una tupla (Major, Minor, Patch) da una stringa"""
    if not version_str:
        return (0, 0, 0)
    match = SEMVER_REGEX.search(version_str)
    if match:
        major = int(match.group(1))
        minor = int(match.group(2))
        patch = int(match.group(3)) if match.group(3) else 0
        return (major, minor, patch)
    return (0, 0, 0)

def determine_bump_type(current, latest):
    """Confronta le tuple e determina il tipo di bump"""
    curr_maj, curr_min, curr_pat = current
    lat_maj, lat_min, lat_pat = latest

    # Se la tupla estratta è 0.0.0 significa che la regex ha fallito (es. tag "latest")
    if current == (0,0,0) or latest == (0,0,0):
        return "unknown"

    if lat_maj > curr_maj:
        return "major"
    elif lat_maj == curr_maj and lat_min > curr_min:
        return "minor"
    elif lat_maj == curr_maj and lat_min == curr_min and lat_pat > curr_pat:
        return "patch"

    return "none"

def get_latest_version_from_rss(url: str):
    """Scarica e parsa il feed XML per trovare l'ultima release stabile"""
    response = requests.get(url, timeout=TIMEOUT, headers=HEADERS)
    response.raise_for_status() # Lancia eccezione se HTTP != 200

    # Rimuove i namespace XML che complicano la ricerca
    xml_data = re.sub(r'\sxmlns="[^"]+"', '', response.text, count=1)
    root = ET.fromstring(xml_data)

    # Cerca tutti i tag <title> dentro le <entry> (Atom feed)
    entries = root.findall('.//entry')
    for entry in entries:
        title_element = entry.find('title')
        if title_element is not None and title_element.text:
            title = title_element.text.strip()
            if is_stable_release(title):
                return title

    raise ValueError("Nessuna release stabile trovata nel feed")

def process_service(service: dict):
    # Inizializziamo i campi di default
    service['latest_version'] = None
    service['bump_type'] = "none"
    service['has_update'] = False
    service['error_detail'] = None

    rss_url = service.get("rss_url")
    current_version = service.get("current_version")

    if not rss_url or current_version == "latest":
        service['error_detail'] = "Nessun RSS URL o versione tracciata come 'latest' (stateless)"
        return service

    try:
        time.sleep(1.5) # Throttling vitale per GitHub

        # 1. Recupera l'ultima versione
        latest_raw = get_latest_version_from_rss(rss_url)
        service['latest_version'] = latest_raw

        # 2. Estrae e confronta il Semver
        curr_tuple = extract_semver(current_version)
        lat_tuple = extract_semver(latest_raw)

        bump = determine_bump_type(curr_tuple, lat_tuple)
        service['bump_type'] = bump

        if bump in ["major", "minor", "patch"]:
            service['has_update'] = True

    except requests.exceptions.RequestException as e:
        service['error_detail'] = f"Errore Rete/HTTP: {str(e)}"
    except ET.ParseError:
        service['error_detail'] = "Errore Parsing XML: Il feed non è valido"
    except Exception as e:
        service['error_detail'] = f"Errore interno: {str(e)}"

    return service

def main():
    try:
        raw_input = sys.stdin.read()
        if not raw_input.strip():
            print(json.dumps([{"error_detail": "Input JSON vuoto dal nodo n8n"}]))
            return
        services = json.loads(raw_input)
    except Exception as e:
        print(json.dumps([{"error_detail": f"Errore parsing JSON: {str(e)}"}]))
        return

    # Processa tutto
    results = [process_service(s) for s in services]

    # Ritorna a n8n (Uscirà sempre con Exit Code 0, quindi n8n non va in Crash)
    print(json.dumps(results))

if __name__ == "__main__":
    main()
