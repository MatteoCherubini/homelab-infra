# **Analisi Architetturale e Protocolli di Automazione per l'Infrastruttura Homelab Nexus**

L'evoluzione della gestione dei sistemi self-hosted ha trasformato il concetto di homelab da semplice ambiente di test a infrastruttura critica per la sovranità dei dati e l'erogazione di servizi personali complessi. L'attuale configurazione dell'host Nexus, basata su Ubuntu Server 24.04 LTS e orchestrata tramite un sistema modulare di Docker Compose, rappresenta un caso di studio avanzato in termini di densità di servizi e necessità di automazione.1 Con oltre 30 container attivi, la manutenzione manuale del ciclo di vita del software, la gestione delle vulnerabilità e l'aggiornamento delle versioni richiedono un approccio sistematico basato sull'integrazione di n8n come motore di orchestrazione operativa.1 Questo rapporto analizza in profondità le sfide tecniche relative alla sicurezza dei webhook, alla gestione delle API esterne, alla configurazione di SSH per l'automazione e alla stabilità del sistema durante le fasi di avvio sequenziale, fornendo soluzioni basate sulle migliori pratiche di ingegneria del software e sicurezza delle infrastrutture.2

## **Analisi dello Stato Attuale e Requisiti di Stabilità**

La struttura del server Nexus si poggia su un processore AMD Ryzen 5 3600 accoppiato a 16GB di RAM DDR4, una dotazione che deve gestire carichi eterogenei che spaziano dai database relazionali (Postgres) ai sistemi di intelligenza artificiale (Ollama).1 L'output di stato dei container rivela una infrastruttura densa ma con alcune criticità immediate, come il riavvio ciclico del servizio Garage S3, che deve essere stabilizzato prima di procedere con qualsiasi piano di automazione su larga scala.1  
Il repository di gestione utilizza un approccio "include" in Docker Compose, separando i servizi in stack funzionali come core, cloud, ai, e monitoring.1 Questo design modulare è fondamentale per l'automazione tramite n8n, poiché permette di isolare l'impatto degli aggiornamenti a singoli segmenti dell'infrastruttura. Tuttavia, la gestione di oltre 30 servizi su una singola macchina introduce colli di bottiglia nelle operazioni di I/O, specialmente considerando l'uso di un array RAID 1 di dischi meccanici da 4TB per i dati persistenti.1

| Parametro Infrastrutturale | Dettaglio Tecnico | Implicazione Operativa |
| :---- | :---- | :---- |
| Sistema Operativo | Ubuntu Server 24.04 LTS | Supporto LTS per stabilità a lungo termine |
| Versione Docker | 29.3.1 | Necessità di allineamento con API moderne |
| Storage Persistente | RAID 1 (2x 4TB HDD) | Latenza I/O critica durante avvii paralleli |
| Rete | VLAN 10 (Trusted) | Isolamento dei servizi critici |
| Accesso Esterno | Cloudflare Tunnel | Bypass CGNAT e protezione DDoS |

L'analisi evidenzia che la stabilità del sistema è influenzata direttamente dalle policy di avvio definite nel Makefile, dove l'uso di COMPOSE\_PARALLEL\_LIMIT=1 suggerisce una chiara intenzione di limitare il carico simultaneo sulla CPU e sui dischi durante la fase di "up".1 Questa scelta è tecnicamente giustificata dalla natura delle dipendenze dei database, dove l'avvio simultaneo di molteplici istanze Postgres (Nextcloud, n8n, Paperless, Immich) potrebbe portare a timeout e corruzione dei dati se le risorse I/O non venissero gestite sequenzialmente.4

## **Sicurezza Avanzata dei Webhook e Protezione SSRF**

L'implementazione di n8n come "Operational Brain" richiede l'esposizione di endpoint webhook per ricevere notifiche di approvazione e segnali di trigger esterni.1 Questo introduce una superficie di attacco significativa se non gestita con protocolli di crittografia e validazione rigorosi.2

### **Validazione HMAC nei Webhook di n8n**

Per garantire l'integrità e l'autenticità dei messaggi ricevuti dai webhook, l'adozione di HMAC (Hash-based Message Authentication Code) è considerata la pratica standard più sicura. A differenza di una semplice chiave API statica, l'HMAC richiede che il mittente firmi il corpo della richiesta (body) utilizzando un segreto condiviso. Il ricevente ricalcola l'hash del body ricevuto e lo confronta con la firma presente nell'header.5  
In n8n, la sfida principale risiede nell'accesso al "raw body" della richiesta. Se la validazione viene eseguita su un oggetto JSON già parsato, anche una minima discrepanza nella formattazione o nell'ordine delle chiavi invaliderà la firma, portando a fallimenti di autenticazione.6 È necessario configurare il nodo Webhook per passare il body grezzo e utilizzare un nodo Code per eseguire il confronto crittografico.  
La funzione di confronto deve obbligatoriamente utilizzare tecniche di comparazione a tempo costante per mitigare gli attacchi di tipo timing. Se il sistema risponde più velocemente quando i primi caratteri di una firma sono corretti, un attaccante potrebbe dedurre la firma carattere per carattere.6 L'utilizzo della funzione crypto.timingSafeEqual in Node.js garantisce che il tempo di risposta sia indipendente dal contenuto della stringa confrontata.6  
Inoltre, la logica di sicurezza deve integrare una "replay window" basata su timestamp. Includere un timestamp nella firma HMAC permette a n8n di rifiutare richieste che hanno più di pochi minuti di vita, impedendo a un attaccante di intercettare e riutilizzare una richiesta legittima (replay attack).6

### **Implementazione della Protezione SSRF**

La protezione contro il Server-Side Request Forgery (SSRF) è vitale in un ambiente homelab dove n8n ha accesso a risorse di rete interne, come le API di Proxmox o il socket di Docker.8 Un attacco SSRF potrebbe permettere a un utente esterno di forzare n8n a inviare comandi a servizi interni non protetti.10  
Dalla versione 2.12.0, n8n offre variabili d'ambiente specifiche per mitigare questo rischio. L'abilitazione di N8N\_SSRF\_PROTECTION\_ENABLED=true attiva un filtro sui nodi che effettuano richieste HTTP, bloccando l'accesso agli indirizzi IP privati (RFC 1918\) e agli endpoint di metadati dei cloud provider (come 169.254.169.254).10  
Per la configurazione di Nexus, è necessario bilanciare questa protezione con la necessità di comunicare con servizi locali. La gerarchia di precedenza dei filtri di n8n prevede che gli hostname autorizzati (N8N\_SSRF\_ALLOWED\_HOSTNAMES) abbiano la precedenza sui blocchi IP.10 Questo consente di autorizzare esplicitamente la comunicazione con Forgejo o Nextcloud tramite il loro nome DNS interno, mantenendo bloccato il resto della rete privata.10

| Variabile d'Ambiente | Impostazione Suggerita | Obiettivo di Sicurezza |
| :---- | :---- | :---- |
| N8N\_SSRF\_PROTECTION\_ENABLED | true | Attivazione del firewall applicativo n8n |
| N8N\_SSRF\_BLOCKED\_IP\_RANGES | default,169.254.169.254/32 | Blocco di reti private e metadati sensibili |
| N8N\_SSRF\_ALLOWED\_HOSTNAMES | forgejo.homelab,npm.homelab | Whitelisting dei servizi interni fidati |
| N8N\_ENCRYPTION\_KEY | Chiave persistente in .env | Protezione delle credenziali a riposo |

## **Gestione dei Limiti di Rate delle API GitHub RSS**

Il piano di automazione prevede il monitoraggio delle versioni tramite feed RSS di GitHub e Codeberg ogni 6 ore.1 Sebbene i feed RSS (come releases.atom) siano pubblici, GitHub applica limiti di rate basati sull'indirizzo IP del richiedente.12

### **Differenze tra Richieste Anonime e Autenticate**

Le richieste anonime verso GitHub sono limitate a 60 all'ora per IP.13 In un homelab con circa 30 servizi, un singolo ciclo di controllo consumerebbe metà del budget orario. Se altri servizi o utenti sulla stessa rete effettuano chiamate a GitHub, il rischio di ricevere un errore HTTP 429 (Too Many Requests) è elevato.12  
L'utilizzo di un Personal Access Token (PAT) eleva questo limite a 5.000 richieste all'ora, fornendo un margine di sicurezza ampiamente sufficiente per Nexus.15 Le chiamate ai feed Atom possono essere autenticate passando il token nell'header Authorization: token \<PAT\>. È fondamentale che n8n memorizzi questo token come credenziale e non lo includa direttamente nei nodi di codice.12  
Oltre ai limiti primari, GitHub impone limiti secondari per prevenire picchi di traffico. Anche con un token, l'invio simultaneo di 30 richieste potrebbe essere interpretato come un comportamento abusivo.13 La logica del workflow WF-1 deve quindi prevedere un ritardo intenzionale (throttling) tra le richieste, idealmente di 1-2 secondi, per garantire una sincronizzazione fluida e costante.15

### **Gestione degli Errori 429 e Header di Reset**

Quando viene raggiunto il limite di rate, GitHub include header specifici nella risposta che indicano quando il limite verrà resettato. Il workflow di n8n deve analizzare l'header X-RateLimit-Reset (espresso in formato Unix Epoch) per determinare quanto tempo attendere prima di tentare nuovamente l'operazione.12 Un'architettura robusta non dovrebbe limitarsi a fallire, ma dovrebbe implementare una logica di "exponential backoff" o mettere in pausa il processo di polling fino al reset del bucket di GitHub.2

| Header GitHub | Significato | Utilizzo nel Workflow n8n |
| :---- | :---- | :---- |
| X-RateLimit-Limit | Massimo numero di richieste consentite | Monitoraggio della quota totale |
| X-RateLimit-Remaining | Richieste residue nel periodo corrente | Decidere se procedere con il polling |
| X-RateLimit-Reset | Timestamp del reset della quota | Configurazione del tempo di attesa |
| X-RateLimit-Used | Numero di richieste già effettuate | Analisi dell'efficienza dei workflow |

## **Configurazione Sicura di n8n Execute Command via SSH**

L'esecuzione di comandi sul sistema host Nexus da un container n8n è una delle operazioni più delicate dal punto di vista della sicurezza. Mentre montare il socket di Docker (/var/run/docker.sock) permetterebbe a n8n di controllare i container, questa pratica è sconsigliata perché un compromesso di n8n equivarrebbe a ottenere i privilegi di root sull'host.11 La soluzione adottata nel piano n8n è l'uso del nodo SSH v2 puntando a un utente non privilegiato.1

### **Paradigma dell'Utente n8n-runner**

L'architettura prevede la creazione di un utente dedicato sul server host, denominato n8n-runner. Questo utente deve avere permessi estremamente limitati:

* Accesso SSH configurato esclusivamente tramite chiavi pubbliche (RSA o Ed25519), disabilitando l'autenticazione tramite password.19  
* Membership nel gruppo docker solo se strettamente necessario, oppure accesso limitato a specifici script tramite sudoers con l'opzione NOPASSWD per comandi granulari come sed o make.1  
* Directory home isolata per evitare che il processo n8n possa leggere file sensibili di altri utenti del server.

Il nodo SSH v2 di n8n facilita questa configurazione, supportando la gestione centralizzata delle credenziali e l'uso di passfasi per le chiavi private.19 Tuttavia, un problema comune nell'automazione SSH riguarda la verifica dell'host key. Durante la prima connessione, SSH richiede la conferma manuale dell'identità del server, un'operazione che blocca un processo automatizzato.21  
Per risolvere questo problema in modo sicuro, è necessario aggiungere preventivamente l'impronta digitale (fingerprint) dell'host Nexus al file known\_hosts all'interno del container n8n.21 L'opzione StrictHostKeyChecking=no, sebbene utilizzata in contesti di test, espone il sistema ad attacchi Man-in-the-Middle e dovrebbe essere evitata in una configurazione di produzione homelab, a meno che la rete non sia considerata totalmente isolata e fidata.21

### **Differenze tra Shell Interattiva e BatchMode**

Un errore frequente nella configurazione del nodo SSH riguarda l'ambiente di esecuzione dei comandi. n8n esegue i comandi in una shell non interattiva, il che significa che i file di profilo dell'utente (come .bashrc o .profile) potrebbero non essere caricati.23 Se il comando make o sed richiede variabili d'ambiente specifiche definite nel profilo utente, queste devono essere passate esplicitamente o caricate nel comando stesso (ad esempio, source /etc/environment && make up).23  
L'utilizzo del parametro \-o BatchMode=yes garantisce che SSH non tenti mai di richiedere input all'utente (come password o conferme), fallendo immediatamente in caso di problemi di autenticazione, il che è preferibile per una gestione pulita degli errori nei log di n8n.23

## **Parsing Semver in n8n per il Confronto delle Versioni**

L'automazione degli aggiornamenti richiede che il sistema sia in grado di distinguere tra Major, Minor e Patch release secondo lo standard Semantic Versioning.1 Questo permette di applicare diverse policy di rischio: aggiornamento automatico per le patch, ma blocco manuale per i cambiamenti di versione major che potrebbero richiedere migrazioni di database.1

### **Logica di Confronto in JavaScript senza Librerie Esterne**

Sebbene sia possibile includere la libreria semver di npm configurando la variabile N8N\_NODES\_INCLUDE\_MODULES, molti utenti preferiscono una soluzione nativa per evitare dipendenze aggiuntive nel nodo Code.25 Una funzione di confronto robusta può essere implementata suddividendo le stringhe di versione tramite il punto e confrontando i segmenti numerici.  
Il confronto deve gestire casi comuni come le versioni estese (es. 2.0.0.1 vs 2.0) e ignorare eventuali prefissi "v" spesso presenti nei tag di GitHub.25 Per versioni semplici, il metodo localeCompare con l'opzione numeric: true è estremamente efficace e conciso: v\_new.localeCompare(v\_old, undefined, { numeric: true }) restituirà 1 se la nuova versione è superiore, 0 se sono uguali e \-1 se la nuova è inferiore.25  
Per una logica più granulare richiesta dal piano Nexus (WF-1), il nodo Code dovrebbe estrarre singolarmente i componenti:

$$Version \= Major.Minor.Patch$$  
Se il segmento Major differisce, il workflow deve etichettare l'aggiornamento come "CRITICO", impedendo l'applicazione automatica tramite SSH.1 Questa distinzione è fondamentale per mantenere l'integrità dei dati, specialmente per servizi come Postgres, dove il salto di versione major (es. da 16 a 17\) non è mai un semplice aggiornamento di immagine ma richiede un dump/restore o l'uso di tool come pg\_upgrade.1

### **Gestione dei Tag Alpha/Beta e Suffix Alfanumerici**

Molti progetti homelab (come Immich) utilizzano tag per release candidate o versioni di sviluppo. La logica di parsing deve essere in grado di gestire stringhe come v2.7.5-cuda o v33.0.2-apache.1 In questi casi, è necessario rimuovere o gestire separatamente il suffisso per evitare che il confronto numerico fallisca o produca risultati errati. Una tecnica comune consiste nel sostituire i caratteri non numerici con un valore negativo per garantire che, ad esempio, 1.1-alpha sia considerato inferiore a 1.1.25

## **Ottimizzazione del Ciclo di Vita Docker e Health Checks**

Con oltre 30 container, il comando docker compose up può diventare un'operazione pesante che satura le risorse del server Nexus.4 L'approccio attuale del Makefile, che impone COMPOSE\_PARALLEL\_LIMIT=1, trasforma l'avvio in un processo sequenziale.1

### **Impatto di COMPOSE\_PARALLEL\_LIMIT=1**

L'impatto reale di questa impostazione è una drastica riduzione del carico di picco su CPU e RAM, al costo di un tempo di avvio totale molto più lungo.4 In una configurazione parallela predefinita, Docker tenta di avviare tutti i container simultaneamente. Questo causa un'esplosione di richieste I/O verso i dischi RAID 1, portando potenzialmente a timeout critici nei servizi che hanno dipendenze strette (come un'applicazione che tenta di connettersi al database prima che questo sia pronto).4  
Imponendo il limite a 1, ogni container viene creato e avviato singolarmente. Questo assicura che il server Nexus possa allocare tutte le risorse necessarie alla corretta inizializzazione di ogni processo, riducendo le probabilità di errori di "Connection Refused" o "I/O timeout".4

### **Tempistiche per il lancio di make health**

Determinare quanto aspettare prima di eseguire make health (il comando che verifica lo stato dei container) è cruciale per evitare falsi negativi.1 In un sistema con 30+ container avviati sequenzialmente, se ogni container impiega mediamente 5-10 secondi per stabilizzarsi, l'intera operazione di make up richiederà dai 150 ai 300 secondi (ovvero 2.5 \- 5 minuti).27  
Il workflow WF-5 (Nightly Deploy) deve quindi prevedere un ritardo significativo o, meglio ancora, una logica di polling.1 Invece di attendere un tempo fisso, n8n dovrebbe monitorare ciclicamente l'output di docker ps o utilizzare lo stato di salute nativo di Docker. Un container è considerato "healthy" solo quando il comando di healthcheck definito nel compose.yml restituisce successo.28

| Stato Docker | Significato Operativo | Azione del Workflow n8n |
| :---- | :---- | :---- |
| starting | Il container è avviato ma non ancora pronto | Attendere il prossimo check |
| healthy | Il servizio è operativo e risponde correttamente | Procedere con il check successivo |
| unhealthy | Il servizio ha fallito i test di prontezza | Inviare allerta urgente tramite ntfy |
| restarting | Il container è in crash loop (es. Garage) | Blocco aggiornamenti e intervento manuale |

L'uso di start\_period nei file compose è fondamentale: fornisce ai database pesanti (come Postgres 18 di n8n o Postgres 16 di Immich) il tempo necessario per eseguire il recupero dai log o l'ottimizzazione degli indici prima che il sistema inizi a contare i fallimenti dei check.28

## **Protocolli di Aggiornamento Sicuro per Vaultwarden e Immich**

Alcuni servizi richiedono attenzioni speciali a causa della sensibilità dei dati o delle dipendenze hardware.1

### **Sicurezza degli Aggiornamenti Vaultwarden**

Vaultwarden gestisce il database delle password e la perdita dei dati sarebbe catastrofica. Sebbene Nexus utilizzi Postgres come backend (offrendo maggiore robustezza rispetto a SQLite), un aggiornamento sicuro deve seguire una procedura rigorosa.30

1. **Backup preventivo:** Prima di cambiare l'immagine, il workflow deve eseguire un pg\_dump del database vaultwarden.31  
2. **Snapshot degli allegati:** È necessario eseguire il backup della directory /data/attachments e dei file rsa\_key\*, poiché questi non risiedono nel database ma sono essenziali per l'accesso ai file cifrati e per l'integrità del sistema.32  
3. **Aggiornamento e Verifica:** Una volta eseguito l'aggiornamento dell'immagine tramite sed e make up, n8n deve verificare che l'endpoint di Vaultwarden restituisca un codice 200 OK prima di considerare l'operazione conclusa.1

L'utilizzo di container dedicati al backup, come vaultwarden-backup, può essere integrato nell'orchestrazione per garantire che ogni aggiornamento sia preceduto da un'esportazione verso uno storage remoto (S3/Garage) o locale cifrato.32

### **Allineamento Immich CUDA e Machine Learning**

Per Immich, l'allineamento delle versioni tra immich-server e immich-machine-learning (ML) è mandatorio. Il servizio ML gestisce compiti intensivi come il riconoscimento facciale e la classificazione delle immagini, interfacciandosi con il server tramite protocolli che cambiano frequentemente tra le release.34  
Inoltre, poiché Nexus utilizza una GPU NVIDIA GTX 1660 Super, l'aggiornamento deve considerare la compatibilità con i driver CUDA dell'host.1 Gli sviluppatori di Immich rilasciano solitamente le immagini ML con tag specifici per CUDA (es. v2.7.5-cuda). Il piano n8n deve assicurarsi che la variabile d'ambiente nel file .env venga aggiornata simultaneamente per entrambi i servizi, evitando che un server aggiornato tenti di comunicare con un worker ML obsoleto, causando il blocco della coda di processing delle immagini.1

| Componente Immich | Requisito di Versione | Dipendenza Hardware |
| :---- | :---- | :---- |
| immich\_server | Deve corrispondere alla release ML | Nessuna specifica |
| immich\_ml | Deve corrispondere alla release Server | NVIDIA Driver \+ CUDA Toolkit |
| immich\_db | Postgres 16 con pgvector | Estensioni vettoriali attive |
| immich\_redis | Valkey 9 | Performance per code di messaggi |

## **Gestione della Notifica e Controllo del Rumore**

Un'automazione eccessivamente verbosa può portare alla "notification fatigue", ovvero la tendenza dell'operatore a ignorare i messaggi a causa della loro frequenza elevata.1 Il piano n8n di Nexus utilizza giustamente ntfy come canale di comunicazione principale, differenziando i livelli di urgenza.1  
Il workflow WF-3 (Weekly Digest) è un esempio eccellente di mitigazione del rumore: raggruppa gli aggiornamenti non critici in un unico riassunto domenicale, fornendo link di approvazione che attivano i webhook HMAC-protetti per l'esecuzione differita.1 Al contrario, il workflow WF-5 deve agire in modo silenzioso in caso di successo (per gli aggiornamenti stateless), ma deve generare un'allerta ad alta priorità in caso di fallimento dei check di salute post-aggiornamento.1  
Questo approccio garantisce che l'attenzione dell'utente sia richiesta solo quando è realmente necessaria una decisione umana o un intervento tecnico correttivo, mantenendo l'infrastruttura Nexus in uno stato di aggiornamento costante ma controllato.1

## **Conclusioni Operative e Roadmap di Implementazione**

L'implementazione del "Operational Brain" su Nexus rappresenta un salto di qualità nella gestione del homelab. Per garantire il successo del piano, è necessario procedere secondo una sequenza logica che priorizzi la sicurezza e la stabilità rispetto alla velocità di automazione.  
In primo luogo, la stabilizzazione dei servizi esistenti (in particolare Garage S3) è un prerequisito non negoziabile; un'infrastruttura che presenta servizi instabili non è una base affidabile per l'automazione del ciclo di vita.1 Successivamente, l'attivazione della protezione SSRF e la configurazione dell'utente SSH n8n-runner getteranno le fondamenta di sicurezza necessarie per permettere a n8n di operare sul sistema host senza esporre il server a rischi eccessivi.10  
La gestione delle versioni tramite Semver e l'uso di token GitHub per il monitoraggio dei feed garantiranno che il sistema sia sempre informato sulle nuove release senza incorrere in blocchi di rate limiting.12 Infine, l'adozione di un ciclo di avvio sequenziale (COMPOSE\_PARALLEL\_LIMIT=1) e di health check rigorosi permetterà a Nexus di gestire i propri 30+ container in modo ordinato, garantendo la disponibilità dei servizi e l'integrità dei dati personali memorizzati nell'homelab.1

#### **Bibliografia**

1. Makefile  
2. n8n Best Practices Checklist for Production (2026) \- HatchWorks AI, accesso eseguito il giorno maggio 12, 2026, [https://hatchworks.com/blog/ai-agents/n8n-best-practices/](https://hatchworks.com/blog/ai-agents/n8n-best-practices/)  
3. n8n Security Best Practices: Protect Your Data and Workflows | Soraia, accesso eseguito il giorno maggio 12, 2026, [https://www.soraia.io/blog/n8n-security-best-practices-protect-your-data-and-workflows](https://www.soraia.io/blog/n8n-security-best-practices-protect-your-data-and-workflows)  
4. Fix COMPOSE\_PARALLEL\_LIMIT · Issue \#8226 · docker/compose \- GitHub, accesso eseguito il giorno maggio 12, 2026, [https://github.com/docker/compose/issues/8226](https://github.com/docker/compose/issues/8226)  
5. Mastering the n8n Webhook Node: Part B — Security, Advanced Scenarios & Deployment, accesso eseguito il giorno maggio 12, 2026, [https://automategeniushub.com/mastering-the-n8n-webhook-node-part-b/](https://automategeniushub.com/mastering-the-n8n-webhook-node-part-b/)  
6. Lock Down n8n Webhooks Before They Bite | by Nexumo \- Medium, accesso eseguito il giorno maggio 12, 2026, [https://medium.com/@Nexumo\_/lock-down-n8n-webhooks-before-they-bite-769e6e8768a0](https://medium.com/@Nexumo_/lock-down-n8n-webhooks-before-they-bite-769e6e8768a0)  
7. Secure public webhooks in n8n with provider signatures \- LumaDock, accesso eseguito il giorno maggio 12, 2026, [https://lumadock.com/tutorials/n8n-webhook-security?language=romanian](https://lumadock.com/tutorials/n8n-webhook-security?language=romanian)  
8. The n8n Hack: Access Environment Variables Safely Without Hardcoding \- Reddit, accesso eseguito il giorno maggio 12, 2026, [https://www.reddit.com/r/n8n/comments/1r8ioix/the\_n8n\_hack\_access\_environment\_variables\_safely/](https://www.reddit.com/r/n8n/comments/1r8ioix/the_n8n_hack_access_environment_variables_safely/)  
9. Security: n8n 2.15.0 ships axios 1.13.5 vulnerable to SSRF (CVE-2025-62718) \#28283, accesso eseguito il giorno maggio 12, 2026, [https://github.com/n8n-io/n8n/issues/28283](https://github.com/n8n-io/n8n/issues/28283)  
10. SSRF protection environment variables | n8n Docs, accesso eseguito il giorno maggio 12, 2026, [https://docs.n8n.io/hosting/configuration/environment-variables/ssrf-protection/](https://docs.n8n.io/hosting/configuration/environment-variables/ssrf-protection/)  
11. \[EN\] N8Naked: exploring security misconfigurations in N8N \- Hakai, accesso eseguito il giorno maggio 12, 2026, [https://hakaisecurity.io/en-n8naked-exploring-security-misconfigurations-in-n8n/research-blog/](https://hakaisecurity.io/en-n8naked-exploring-security-misconfigurations-in-n8n/research-blog/)  
12. Error: 429 Too Many Requests — You've been rate limited | by Bearer \- Medium, accesso eseguito il giorno maggio 12, 2026, [https://medium.com/@BearerSH/error-429-too-many-requests-youve-been-rate-limited-a4d41e94b8e6](https://medium.com/@BearerSH/error-429-too-many-requests-youve-been-rate-limited-a4d41e94b8e6)  
13. A Developer's Guide: Managing Rate Limits for the GitHub API \- Lunar.dev, accesso eseguito il giorno maggio 12, 2026, [https://www.lunar.dev/post/a-developers-guide-managing-rate-limits-for-the-github-api](https://www.lunar.dev/post/a-developers-guide-managing-rate-limits-for-the-github-api)  
14. GitHub API Rate Limits in 2026: When Web Scraping Is the Better Choice \- DEV Community, accesso eseguito il giorno maggio 12, 2026, [https://dev.to/agenthustler/github-api-rate-limits-in-2026-when-web-scraping-is-the-better-choice-hdo](https://dev.to/agenthustler/github-api-rate-limits-in-2026-when-web-scraping-is-the-better-choice-hdo)  
15. Rate limits for the REST API \- GitHub Docs, accesso eseguito il giorno maggio 12, 2026, [https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)  
16. Getting started with the REST API \- GitHub Docs, accesso eseguito il giorno maggio 12, 2026, [https://docs.github.com/en/rest/overview/resources-in-the-rest-api?apiVersion=2022-11-28\#rate-limiting](https://docs.github.com/en/rest/overview/resources-in-the-rest-api?apiVersion=2022-11-28#rate-limiting)  
17. Rate Limit Cheatsheet for Self-Hosting Github Runners \- WarpBuild Blog, accesso eseguito il giorno maggio 12, 2026, [https://www.warpbuild.com/blog/rate-limits-self-hosted-runners](https://www.warpbuild.com/blog/rate-limits-self-hosted-runners)  
18. GitHub \- xsukax/xsukax-RSS-to-Mastodon: Self-hosted Python web app that auto-posts RSS/Atom feeds to multiple Mastodon accounts. Single-file, multi-instance, per-feed hashtags, live scheduler dashboard, OAuth 2.0, CSRF protection, and SQLite storage \- no cloud, no tracking, full control., accesso eseguito il giorno maggio 12, 2026, [https://github.com/xsukax/xsukax-RSS-to-Mastodon](https://github.com/xsukax/xsukax-RSS-to-Mastodon)  
19. SSH credentials \- n8n Docs, accesso eseguito il giorno maggio 12, 2026, [https://docs.n8n.io/integrations/builtin/credentials/ssh/](https://docs.n8n.io/integrations/builtin/credentials/ssh/)  
20. SSH \- n8n Docs, accesso eseguito il giorno maggio 12, 2026, [https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.ssh/](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.ssh/)  
21. Git error: "Host Key Verification Failed" when connecting to remote repository, accesso eseguito il giorno maggio 12, 2026, [https://stackoverflow.com/questions/13363553/git-error-host-key-verification-failed-when-connecting-to-remote-repository](https://stackoverflow.com/questions/13363553/git-error-host-key-verification-failed-when-connecting-to-remote-repository)  
22. How to Publish Your Lovable App to InMotion Hosting via GitHub, accesso eseguito il giorno maggio 12, 2026, [https://www.inmotionhosting.com/support/website/git/publish-lovable-webapp-via-github/](https://www.inmotionhosting.com/support/website/git/publish-lovable-webapp-via-github/)  
23. SSH node doesn't execute commands on SSH v2 server · Issue \#16237 · n8n-io/n8n, accesso eseguito il giorno maggio 12, 2026, [https://github.com/n8n-io/n8n/issues/16237](https://github.com/n8n-io/n8n/issues/16237)  
24. IBM Platform MPI User's Guide | PDF | Message Passing Interface \- Scribd, accesso eseguito il giorno maggio 12, 2026, [https://www.scribd.com/document/635142736/IBM-Platform-MPI-User-s-Guide](https://www.scribd.com/document/635142736/IBM-Platform-MPI-User-s-Guide)  
25. algorithm \- How can I compare software version number using ..., accesso eseguito il giorno maggio 12, 2026, [https://stackoverflow.com/questions/6832596/how-to-compare-software-version-number-using-js-only-number](https://stackoverflow.com/questions/6832596/how-to-compare-software-version-number-using-js-only-number)  
26. n8n: Code Node \- Import external library (Python & JavaScript) \- DEV Community, accesso eseguito il giorno maggio 12, 2026, [https://dev.to/codebangkok/n8n-code-node-import-external-library-python-javascript-4lp7](https://dev.to/codebangkok/n8n-code-node-import-external-library-python-javascript-4lp7)  
27. How to Optimize Docker Compose Startup Speed \- OneUptime, accesso eseguito il giorno maggio 12, 2026, [https://oneuptime.com/blog/post/2026-02-08-how-to-optimize-docker-compose-startup-speed/view](https://oneuptime.com/blog/post/2026-02-08-how-to-optimize-docker-compose-startup-speed/view)  
28. Clarification on Docker Compose's \`start\_period\` parameter \- Stack Overflow, accesso eseguito il giorno maggio 12, 2026, [https://stackoverflow.com/questions/53289950/clarification-on-docker-composes-start-period-parameter](https://stackoverflow.com/questions/53289950/clarification-on-docker-composes-start-period-parameter)  
29. Set the 'start-interval' of a healthcheck in docker-compose.yml \- Stack Overflow, accesso eseguito il giorno maggio 12, 2026, [https://stackoverflow.com/questions/76758501/set-the-start-interval-of-a-healthcheck-in-docker-compose-yml](https://stackoverflow.com/questions/76758501/set-the-start-interval-of-a-healthcheck-in-docker-compose-yml)  
30. 1O / Vaultwarden Backup \- GitLab, accesso eseguito il giorno maggio 12, 2026, [https://gitlab.com/1O/vaultwarden-backup](https://gitlab.com/1O/vaultwarden-backup)  
31. vaultwarden-backup/docs/using-the-postgresql-backend.md at master \- GitHub, accesso eseguito il giorno maggio 12, 2026, [https://github.com/ttionya/vaultwarden-backup/blob/master/docs/using-the-postgresql-backend.md](https://github.com/ttionya/vaultwarden-backup/blob/master/docs/using-the-postgresql-backend.md)  
32. ttionya/vaultwarden-backup: Backup vaultwarden (formerly known as bitwarden\_rs) SQLite3/PostgreSQL/MySQL/MariaDB database by rclone. (Docker) \- GitHub, accesso eseguito il giorno maggio 12, 2026, [https://github.com/ttionya/vaultwarden-backup](https://github.com/ttionya/vaultwarden-backup)  
33. Vaultwarden Dual Backup Deploy Guide \- Zeabur, accesso eseguito il giorno maggio 12, 2026, [https://zeabur.com/templates/SF94LY](https://zeabur.com/templates/SF94LY)  
34. Environment Variables | Immich, accesso eseguito il giorno maggio 12, 2026, [https://immich.app/docs/install/environment-variables\#machine-learning-settings](https://immich.app/docs/install/environment-variables#machine-learning-settings)  
35. How to Secure n8n Workflows: Step-by-Step Process \- Reco AI, accesso eseguito il giorno maggio 12, 2026, [https://www.reco.ai/hub/secure-n8n-workflows](https://www.reco.ai/hub/secure-n8n-workflows)