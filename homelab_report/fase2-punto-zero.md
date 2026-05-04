# 🛡️ Homelab Infrastructure: Resoconto Consolidato

**Data:** 4 Maggio 2026

**Stato Progetto:** Fase 2 (Avanzata)

**Obiettivo:** Bypass blocco ISP, consolidamento storage e sicurezza perimetrale.

- - -

## 1\. Analisi Situazione Iniziale e "Muro" ISP

L'infrastruttura si basa su un nodo firewall (**ZimaBoard/OPNsense**) e un nodo compute (**Nexus/Docker**).

*   **Problema Bloccante:** L'ISP (Tiscali) blocca il traffico in ingresso sulle porte standard **80 (HTTP)** e **443 (HTTPS)**.

*   **Conseguenza:** Il Port Forwarding (NAT) tradizionale su OPNsense è inefficace per esporre i servizi web (Nextcloud, Vaultwarden, ecc.) all'esterno.

*   **Soluzione Adottata:** Abbandono del NAT in favore di un **Cloudflare Tunnel (Argo)** per creare una connessione outbound sicura.


- - -

## 2\. Interventi Critici Eseguiti

### 💾 A. Consolidamento Storage (Il "RAID Fix")

Durante l'analisi è stata scoperta una criticità grave: l'array RAID 1 (`/dev/md0`) non era montato correttamente. I dati venivano scritti silenziosamente sul disco di sistema (SSD), rischiando di saturarlo.

*   **Azione:** 1. Identificato l'UUID corretto dell'array (`acd20205...`). 2. Modificato `/etc/fstab` per rendere il mount `/mnt/md0` persistente. 3. Eseguito `systemctl daemon-reload` e `mount -a`. 4. Migrati i dati esistenti dalla directory temporanea dell'SSD al vero RAID.

*   **Risultato:** I servizi ora scrivono correttamente sui 3.6TB del RAID 1.


### 🌐 B. Bypass ISP via Cloudflare Tunnel

Per aggirare i limiti delle porte chiuse, abbiamo implementato un tunnel criptato.

*   **Componente:** Aggiunto container `cloudflared` allo stack `core`.

*   **Configurazione:** Il tunnel stabilisce una connessione in uscita verso Cloudflare. Non è più necessario aprire porte sulla WAN di OPNsense.

*   **Risoluzione Conflitti:** Eliminati i vecchi record DNS (A/CNAME) su Cloudflare che andavano in conflitto con la creazione automatica dei record del tunnel.


### 🚦 C. Nginx Proxy Manager (NPM) come "Vigile"

NPM è stato configurato per essere il terminale interno del tunnel.

*   **Flusso Traffico:** `Internet` → `Cloudflare (Edge)` → `Tunnel` → `NPM (Porta 80)` → `Container (Nextcloud, ecc.)`.

*   **Certificati SSL:** - Esterno: Gestito da Cloudflare (SSL/TLS modo "Flexible" o "Full").

    *   Interno: Challenge DNS-01 configurata per ottenere certificati Wildcard `*.keruhomelab.com` bypassando il blocco della porta 80.


### 🔍 D. Ottimizzazione Rete (Split DNS)

Per evitare che il traffico interno faccia il giro da internet (loopback):

*   **Azione:** Configurato **Unbound DNS** su OPNsense con _Host Overrides_.

*   **Risultato:** Quando sei in casa (VLAN Trusted), `cloud.keruhomelab.com` viene risolto direttamente sull'IP locale di Nexus (`10.0.10.20`), garantendo velocità LAN.


- - -

## 3\. Stato Attuale dei Servizi (Nexus)

| Servizio | Stato | Accesso | Nota |
| --- | --- | --- | --- |
| **Nginx Proxy Manager** | ✅ UP | Port 81 (Admin) | Gestisce il routing interno. |
| **Cloudflared** | ✅ UP | Zero Trust Dashboard | Bridge verso l'esterno. |
| **Nextcloud** | ✅ UP | cloud.keruhomelab.com | Storage sul RAID attivo. |
| **Vaultwarden** | ✅ UP | vault.keruhomelab.com | Password manager protetto. |
| **Forgejo** | ✅ UP | git.keruhomelab.com | Git server attivo. |
| **Garage S3** | ⚠️ STOP | \-  | In attesa di file `garage.toml`. |
| **Ollama** | ✅ UP | Locale / Open WebUI | Profilo CPU/GPU attivo. |

Esporta in Fogli

- - -

## 4\. Prossimi Passi (Roadmap)

1.  **Chiusura Firewall:** Eliminare definitivamente le regole di Port Forward 80/443 su OPNsense (non più necessarie).

2.  **Hardening SSH:** Verificare che l'accesso a Nexus e OPNsense avvenga esclusivamente tramite chiavi Ed25519 (disabilitare password auth).

3.  **Setup VPN (Headscale):** Configurazione per l'accesso amministrativo remoto (non-web) tramite mesh network.

4.  **Monitoring:** Attivazione dello stack Grafana/Loki per il controllo dei log e delle performance termiche di Nexus.

5.  **Backup Offsite:** Configurazione di Kopia per replicare i dati del RAID su un bucket S3 esterno (o Garage remoto).


- - -

### 📝 Note di Manutenzione

*   **Pulizia SSD:** Una volta verificata l'integrità dei dati su `/mnt/md0`, eseguire `sudo rm -rf /mnt/md0_finto` per recuperare spazio sul disco di sistema.

*   **Log Tunnel:** Monitorare i log del container `cloudflared` per eventuali disconnessioni dovute a cali della linea Tiscali.


- - -
