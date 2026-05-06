# Architettura Unificata LLM Knowledge Genome su Ecosistema Keru Homelab
*Documento di Specifica Architetturale e Studio di Fattibilità*
*Data: Maggio 2026*

## 1. Topologia di Rete e Mappatura dei Ruoli (VLAN 10 - Trusted)

L'implementazione del "Knowledge Genome" sfrutta l'architettura a tre nodi già esistente nell'homelab, mantenendo tutto il traffico sensibile (inclusa l'elaborazione dei documenti privati) isolato e protetto all'interno della **VLAN 10 (10.0.10.0/24)** gestita da OPNsense.

### 1.1 AMD Nexus (10.0.10.20) — Sorgente di Verità e Percezione
Il server Nexus funge da hub di archiviazione, gateway sicuro e sistema di pre-elaborazione (OCR).
* **Gestione Git (Sorgente di Verità)**: Ospita lo stack Docker `git` con **Forgejo** (`git.keruhomelab.com`). Qui risiede fisicamente l'intero albero dei repository del Genoma. Il traffico locale vi accede via Split DNS (Unbound su ZimaBoard) sulla porta 443 gestita da Nginx Proxy Manager, senza uscire su WAN.
* **Storage Persistente**: L'array RAID 1 da 4TB in `/mnt/md0/homelab_data/` offre uno spazio virtualmente inesauribile per l'accumulo dei file RAW (PDF, asset visivi, pacchetti codebase Angular).
* **Elaborazione RAW (Ingestione)**: La GPU NVIDIA GTX 1660 Super (6GB) è sufficiente per ospitare container dedicati all'estrazione documentale (es. Docling con plugin GLM-OCR) per i carichi batch asincroni, liberando il nodo principale da compiti di basso livello.

### 1.2 Torre Intel (10.0.10.11 - VM 101 "AI") — Cervello e Sintesi
La futura VM 101 su Proxmox (`10.0.10.10`) diventerà il motore esecutivo del Genoma.
* **Hardware Dedicato**: 8 core della CPU Intel Ultra 7 265K, 32GB di RAM DDR5 e passthrough completo della GPU NVIDIA RTX 5060 Ti (16GB VRAM).
* **Motore di Ragionamento**: Esecuzione di **DeepSeek-V4-Flash** tramite Ollama/vLLM. La VRAM da 16GB gestisce perfettamente i 13B parametri attivi del modello MoE, garantendo l'utilizzo dell'intera finestra di contesto da 1 milione di token per l'analisi di interi progetti pacchettizzati via Repomix.
* **MCP Server (qmd)**: Demone HTTP per l'indicizzazione e la ricerca ibrida (vettoriale + lessicale + reranking) che mappa i sottomoduli del genoma in tempo reale.

### 1.3 Laptop Dell (10.0.10.x DHCP) — Interfaccia Umana
* **IDE del Pensiero**: Utilizzo di Obsidian connesso via plugin Obsidian Git.
* **Accesso Sicuro**: Quando in rete locale, accede direttamente a Forgejo via `10.0.10.20`. Da remoto, sfrutta Cloudflare Tunnel (via `cloudflared` su Nexus) o la VPN mesh (Headscale).

---

## 2. Architettura Dati: Multi-Submodule Git

Il repository non è monolitico. Per garantire scalabilità sul file system RAID di Nexus e privacy in caso di condivisione, viene utilizzata una struttura a sottomoduli multipli orchestrata su Forgejo.

### Struttura del Workspace
```text
/master-knowledge-genome (Repo Master su Forgejo)
├── .gitmodules
├── core-karpathy/       (Submodule: Logica di sistema upstream)
├── genome-dev/          (Submodule: Sviluppo Web, TUI, Angular)
│   ├── raw/             (Sorgenti immutabili, codebase Repomix)
│   └── wiki/            (Pagine index.md, concepts, entities)
├── genome-finance/      (Submodule: Finanza e Investimenti)
│   ├── raw/
│   └── wiki/
├── genome-homelab/      (Submodule: Architettura Keru, log reti)
│   ├── raw/
│   └── wiki/
└── AGENTS.md            (Schema globale di coordinamento)
````

**Vantaggi Integrati:**

*   **GitKraken/Sparse Checkout sul Laptop**: Il Dell scarica in RAM solo i sottomoduli attivi.

*   **Sicurezza Forgejo**: Ogni sottomodulo è un repository Forgejo indipendente, permettendo webhook separati (es. un caricamento su `genome-dev/raw` non trigghera l'indicizzazione di `genome-finance`).


- - -

## 3\. Sviluppo AI-Native: Angular 21 MCP e Skills Management

All'interno del `genome-dev/`, l'interazione con framework complessi viene mediata da protocolli standardizzati per evitare allucinazioni dell'LLM (sulla VM 101).

### 3.1 Angular 21 MCP Server

L'agente (DeepSeek-V4-Flash) interroga direttamente il comando nativo `ng mcp` della CLI di Angular 21:

*   **Comando `list_projects`**: L'LLM legge autonomamente `angular.json` per comprendere l'architettura.

*   **Comandi di Migrazione**: Tool sperimentali (`modernize`, `onpush_zoneless_migration`) permettono all'agente di preparare PR per refactoring mirati senza intervento manuale sul codice sorgente.

*   **`search_documentation`**: Bridge per accedere ad angular.dev per superare il knowledge cutoff.


### 3.2 Orchestrazione con skills.sh

L'ambiente operativo della VM 101 utilizza `skills.sh` per definire i perimetri di azione dell'LLM:

*   Gli agenti leggono file `SKILL.md` (es. "Skill: Angular Component Extraction") che obbligano DeepSeek a usare routine prestabilite per produrre commit convenzionali.


- - -

## 4\. Flusso Operativo: Git Flow e Human-in-the-Loop

La regola aurea del sistema impedisce all'LLM di scrivere direttamente sulla knowledge base principale, trasformando l'operazione in un processo di ingegneria del software revisionata.

1.  **Ingestione Umana**: Dal Laptop (o in mobilità via VPN Headscale), l'utente inserisce un nuovo documento (es. PDF architetturale) in `genome-homelab/raw/` e ne esegue il push verso Forgejo (`git.keruhomelab.com`).

2.  **Trigger Webhook**: Forgejo invia un webhook alla VM 101 (Torre Intel `10.0.10.11`).

3.  **Branching AI**: L'agente sulla VM esegue `git checkout -b feat/ai-ingest-[nome-doc]`.

4.  **Elaborazione (Se necessaria)**: Se il file è un PDF complesso, la VM 101 invia una richiesta API al container Docling/GLM-OCR su Nexus (`10.0.10.20`) e riceve il Markdown strutturato.

5.  **Sintesi e Relazione**: DeepSeek-V4-Flash analizza il Markdown, incrocia i dati con l'indice `qmd`, aggiorna i file `.md` nella cartella `wiki/` inserendo i wikilink corretti.

6.  **Micro-Commit e PR**: L'agente esegue micro-commit (es. `feat(wiki): add OPNsense VLAN details`) e apre una Pull Request automatica su Forgejo.

7.  **Validazione Umana**: L'utente, tramite l'interfaccia web di Forgejo (dietro proxy NPM) o Obsidian sul laptop, verifica la PR. Solo dopo l'approvazione, i dati entrano in `main/wiki/`.


- - -

## 5\. Analisi di Fattibilità Tecnica e Colli di Bottiglia

In base alla struttura "homelab-struttura-maggio2026.md", l'architettura risulta **pienamente fattibile** e ottimizzata, rispettando i seguenti vincoli:

| Sottosistema | Analisi di Carico e Fattibilità | Stato |
| --- | --- | --- |
| **Banda di Rete (LAN)** | I trasferimenti tra Nexus (Storage) e Torre Intel (Inferenza) avvengono su trunk/VLAN 10 (switch Gigabit). Spostare pacchetti Markdown o JSON via API RAG non satura la banda. L'uso dello Split DNS garantisce latenza sub-millisecondo tra domini locali. | ✅ OK |
| **Tunnel Cloudflare** | Le policy CSRF degli AI Agent spesso falliscono se esposte su reti pubbliche mal configurate. Nel `compose` di Forgejo su Nexus, la configurazione `REVERSE_PROXY_TRUSTED_PROXIES` garantisce che i webhook non vengano rigettati o intercettati dai filtri WAF di Cloudflare. | ⚠️ Richiede Tuning `compose` |
| **Gestione VRAM (Intel)** | DeepSeek-V4-Flash richiederà quasi tutta la VRAM della RTX 5060 Ti (16GB) per contesti massimi (1M token). È essenziale dedicare questa GPU _esclusivamente_ a Ollama/vLLM nella VM 101, senza container accessori che "rubino" memoria. | ✅ OK |
| **Gestione VRAM (AMD)** | La GTX 1660 Super su Nexus (6GB) continuerà a gestire l'OCR (1.6GB richiesti per GLM-OCR) e i modelli leggeri (es. Llama 3 8B), garantendo che Nexus rimanga reattivo per gli altri 29 container attivi. | ✅ OK |
| **Storage (IOPS)** | Forgejo su PostgreSQL (`n8n-db`, `nextcloud-db`) e i volumi dei repository Git risiedono sull'array RAID 1 in `md0`. L'I/O intensivo causato da continui micro-commit dell'LLM sarà assorbito agevolmente dalla combinazione SSD (OS) + HDD (dati). | ✅ OK |

Esporta in Fogli

### 5.1 Requisiti di Sicurezza Aggiuntivi per l'Integrazione

Per implementare l'architettura in sicurezza nell'homelab attuale:

1.  **VLAN Firewall Rules**: Implementare in OPNsense l'Alias `SERVER_AI (10.0.10.11)` con permessi stringenti (`PASS TCP TRUSTED -> SERVER_AI:11434` e porta SSH).

2.  **SSH Hardening**: L'agente AI nella VM 101 dovrà comunicare con Forgejo su Nexus (`10.0.10.20:222`) unicamente tramite chiavi Ed25519 (password auth disabilitata).

3.  **Headscale Client**: Configurare i client per garantire l'accesso d'emergenza alle PR su Forgejo qualora il tunnel Cloudflare dovesse subire rate-limiting causato da troppi webhook automatizzati.
