#!/usr/bin/env python3
import json
import requests
import xml.etree.ElementTree as ET
import sys
import time

TIMEOUT = 10
MAX_BODY_SIZE = 1024 * 500  # 500 KB max per evitare saturazione RAM
HEADERS = {
    # Usiamo un agent standard per non farci bloccare dall'anti-bot di GitHub
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Accept": "application/atom+xml, application/rss+xml, application/xml, text/xml"
}

def is_valid_xml_feed(content: str) -> bool:
    try:
        # Prevenzione XML bomb: controlliamo solo le primissime righe
        if not content.strip().startswith('<'):
            return False
        root = ET.fromstring(content)
        tag = root.tag.lower()
        return any(x in tag for x in ["rss", "feed", "rdf"])
    except:
        return False

def check_service(service: dict):
    name = service.get("display_name") or service.get("compose_name")
    rss_url = service.get("rss_url")

    service["rss_check_ok"] = False
    service["rss_error_detail"] = None

    if not rss_url:
        service["rss_error_detail"] = "URL mancante"
        return service

    try:
        # Aggiungiamo un ritardo di 1.5s per evitare il rate-limiting di GitHub (429 Too Many Requests)
        time.sleep(1.5)

        response = requests.get(rss_url, timeout=TIMEOUT, headers=HEADERS, allow_redirects=True)

        # Se lo status non è 200, ci fermiamo subito senza leggere il body
        if response.status_code != 200:
            service["rss_error_detail"] = f"HTTP {response.status_code}"
            return service

        # Leggiamo il body con cautela per non riempire la RAM
        body = response.text[:MAX_BODY_SIZE]

        if "<html" in body.lower():
            service["rss_error_detail"] = "Ricevuto HTML invece di XML (Possibile ban o rate limit)"
        elif not is_valid_xml_feed(body):
            service["rss_error_detail"] = "XML non valido o non è un Feed"
        else:
            service["rss_check_ok"] = True

    except requests.exceptions.Timeout:
        service["rss_error_detail"] = "Timeout"
    except Exception as e:
        service["rss_error_detail"] = f"Errore interno: {str(type(e).__name__)}"

    return service

def main():
    try:
        raw_input = sys.stdin.read()
        if not raw_input.strip():
            print(json.dumps([{"error": "Input vuoto"}]))
            return
        services = json.loads(raw_input)
    except Exception as e:
        print(json.dumps([{"error": f"Errore parsing JSON: {str(e)}"}]))
        return

    results = [check_service(s) for s in services]
    print(json.dumps(results, indent=2))

if __name__ == "__main__":
    main()
