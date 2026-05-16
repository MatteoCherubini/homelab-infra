#!/usr/bin/env python3
import json
import requests
import xml.etree.ElementTree as ET
import sys

TIMEOUT = 10
HEADERS = {
    "User-Agent": "rss-checker/1.0",
    "Accept": "application/atom+xml, application/rss+xml, application/xml, text/xml"
}

def is_valid_xml_feed(content: str) -> bool:
    try:
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
        response = requests.get(rss_url, timeout=TIMEOUT, headers=HEADERS, allow_redirects=True)
        body = response.text or ""
        
        if response.status_code != 200:
            service["rss_error_detail"] = f"HTTP {response.status_code}"
        elif "<html" in body.lower():
            service["rss_error_detail"] = "Ricevuto HTML invece di XML"
        elif not is_valid_xml_feed(body):
            service["rss_error_detail"] = "XML non valido o non è un Feed"
        else:
            service["rss_check_ok"] = True
            
    except requests.exceptions.Timeout:
        service["rss_error_detail"] = "Timeout"
    except Exception as e:
        service["rss_error_detail"] = str(type(e).__name__)

    return service

def main():
    # Legge l'input da n8n
    try:
        raw_input = sys.stdin.read()
        if not raw_input:
            print(json.dumps([]))
            return
        services = json.loads(raw_input)
    except Exception as e:
        print(json.dumps([{"error": f"Errore parsing input: {str(e)}"}]))
        return

    # Esegue il check per tutti i servizi ricevuti
    results = [check_service(s) for s in services]
    
    # Restituisce il JSON finale a n8n
    print(json.dumps(results))

if __name__ == "__main__":
    main()
