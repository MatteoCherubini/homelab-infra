# **Architettura del Knowledge Genome: Analisi Tecnica per una Wiki Distribuita basata sul Modello Karpathy, QMD e SearXNG in Ambiente Homelab Ibrido AMD-Intel**

L’evoluzione dei sistemi di gestione della conoscenza personale ha subito una trasformazione radicale con l'avvento dei Large Language Models (LLM), passando da semplici archivi statici a entità dinamiche e sintetiche. La presente analisi tecnica delinea l'implementazione di quello che viene definito "Knowledge Genome", un'architettura wiki modulare e distribuita ispirata al pattern "LLM Wiki" di Andrej Karpathy.1 Il sistema si fonda sull'integrazione di strumenti di ricerca avanzata come qmd (Query Markdown Documents) e motori di meta-ricerca come SearXNG, orchestrati su un'infrastruttura homelab eterogenea che vede un nodo AMD dedicato allo storage e al sourcing e un nodo Intel Proxmox per il calcolo computazionale e la gestione delle macchine virtuali.2  
L'obiettivo fondamentale di questa architettura è superare i limiti intrinseci della Retrieval-Augmented Generation (RAG) tradizionale, la quale spesso soffre di una mancanza di persistenza e di un accumulo di conoscenza frammentario.1 Invece di limitarsi a recuperare frammenti di testo grezzo per ogni singola query, il Knowledge Genome agisce come un artefatto in continua crescita, dove l'LLM assume il ruolo di "programmatore della conoscenza", incaricato di compilare, collegare e mantenere un repository strutturato in Markdown.2

## **Fondamenti Concettuali del Pattern LLM Wiki**

Il fulcro teorico dell'architettura risiede nella convinzione che la conoscenza debba essere trattata come un codebase persistente. Secondo le osservazioni di Karpathy, i sistemi RAG convenzionali sono inefficienti perché "ri-derivano" la conoscenza da chunk grezzi ogni volta che viene posta una domanda, senza che nulla si accumuli nel tempo.1 Il pattern proposto ribalta questa dinamica: quando una nuova fonte viene acquisita, l'LLM la sintetizza una sola volta all'interno di una wiki persistente di cui l'agente stesso è proprietario e manutentore.1 Le query successive leggono la wiki pre-sintetizzata anziché le fonti grezze originali, permettendo una navigazione più fluida e una comprensione più profonda delle interconnessioni tra i concetti.1  
Questa metodologia trasforma l'LLM da semplice risponditore di domande a gestore di un grafo della conoscenza. Il sistema non si limita a riassumere un documento, ma aggiorna le pagine delle entità, revisiona le sintesi esistenti e segnala eventuali contraddizioni emerse dal confronto tra vecchie e nuove informazioni.2 Tale approccio crea un "debito intellettuale positivo", dove ogni interazione con il sistema rafforza la struttura informativa complessiva, portando a quella che Karpathy definisce una wiki "sempre più densa, non solo più grande".4

### **Struttura a Tre Livelli e Flussi Operativi**

L'architettura del Knowledge Genome è organizzata in tre strati logici distinti, ciascuno con responsabilità e proprietari chiari 2:

| Livello | Funzione | Proprietà | Caratteristiche |
| :---- | :---- | :---- | :---- |
| **Raw Sources** | Fonte della verità immutabile | Utente / Sourcing Agent | PDF, paper, immagini, log tecnici originali. |
| **The Wiki** | Sintesi strutturata e interconnessa | LLM Agent | File Markdown, pagine entità, indici, log di sistema. |
| **The Schema** | Regole di ingaggio e convenzioni | Utente (Architetto) | CLAUDE.md, standard di metadati, regole di linting. |

Il flusso operativo si divide in tre fasi principali: ingestione, interrogazione e manutenzione (linting).2 Durante l'ingestione, l'LLM elabora i documenti nella cartella raw/, discute i punti chiave con l'utente e procede all'aggiornamento di circa 10-15 pagine wiki correlate, oltre all'indice principale index.md.2 La fase di interrogazione permette all'utente di ottenere risposte sintetizzate direttamente dalle pagine wiki, le quali possono essere a loro volta ri-archiviate come nuove pagine permanenti.2 Infine, il "linting" periodico assicura che non vi siano link rotti, pagine orfane o contraddizioni logiche, mantenendo l'integrità strutturale del repository.1

## **Distribuzione Hardware e Orchestrazione dei Nodi**

L'implementazione pratica del Knowledge Genome richiede una separazione strategica tra le operazioni di I/O intensive e le attività di calcolo neurale. L'architettura proposta distribuisce i carichi di lavoro su due nodi hardware distinti all'interno dell'homelab, ottimizzando le prestazioni in base alle caratteristiche specifiche dei processori AMD e Intel.2

### **Il Nodo AMD Nexus: Storage, Sourcing e Versioning**

Il server Nexus basato su AMD è designato come il cuore pulsante dei dati. Data la tendenza delle architetture AMD a offrire un numero elevato di core e linee PCIe, questo nodo è ideale per gestire lo stack di storage e i servizi di meta-ricerca.2 La configurazione prevede un array RAID 1 (md0) che ospita i volumi dei repository Git (tramite Forgejo), i database PostgreSQL e le istanze Docker per SearXNG e n8n.2  
L'utilizzo di un array RAID 1 è fondamentale per garantire la continuità del servizio e la protezione dei dati contro i guasti hardware, specialmente considerando l'elevata frequenza di micro-commit generati dagli agenti AI durante le fasi di ingestione.2 Il nodo AMD gestisce anche il traffico di rete interno tramite Split DNS, permettendo la risoluzione locale di servizi come git.keruhomelab.com senza transitare per la rete esterna, riducendo drasticamente la latenza.2

### **Il Nodo Intel Proxmox: Virtualizzazione, AI e Sviluppo**

Il secondo nodo hardware, basato su Intel, esegue Proxmox VE per la gestione delle macchine virtuali (VM) dedicate al calcolo AI e agli ambienti di sviluppo.2 Le istruzioni specifiche dei processori Intel e la loro maturità nella virtualizzazione rendono questo nodo perfetto per ospitare gli agenti di ragionamento che devono interagire con la wiki.2  
Le VM in questo ambiente montano i repository della wiki residenti sul nodo AMD tramite protocollo NFS (Network File System).2 Questa configurazione permette agli agenti AI di operare su un filesystem che appare locale, beneficiando della velocità dell'interconnessione LAN a 2.5 Gb/s o superiore, mentre i dati reali rimangono protetti sull'array RAID del server Nexus.6

### **Analisi Comparativa dell'Infrastruttura Distribuita**

| Componente | Nodo AMD Nexus | Nodo Intel Proxmox |
| :---- | :---- | :---- |
| **Ruolo Primario** | Data Sourcing e Storage | Ragionamento AI e Dev |
| **Tecnologia Base** | Docker | VM Proxmox / LXC |
| **Storage** | RAID 1 (md0) | Boot locale / NFS Remoto |
| **Servizi Chiave** | Forgejo, SearXNG, n8n | Claude Code, Local LLM, qmd |
| **Vantaggio** | Efficienza I/O e multi-threading | Ottimizzazione virtualizzazione |

La separazione tra i due nodi previene i colli di bottiglia tipici dei sistemi monolitici, dove un'intensa attività di inferenza LLM potrebbe saturare le risorse necessarie per il mantenimento del filesystem o per l'indicizzazione dei dati.2

## **Sourcing dei Dati: Integrazione di SearXNG**

Per alimentare lo strato delle "Raw Sources", l'architettura integra SearXNG, un motore di meta-ricerca open-source che garantisce privacy e assenza di costi di licenza.3 SearXNG viene distribuito in un container Docker sul nodo AMD Nexus, agendo come gateway tra gli agenti di ricerca e l'internet pubblico.3

### **Configurazione per l'Accesso Programmatico**

Affinché gli agenti AI possano utilizzare SearXNG come strumento di sourcing, è necessario abilitare l'output in formato JSON, che per impostazione predefinita è disattivato per motivi di sicurezza.9 Questo avviene tramite la modifica del file settings.yml nel volume Docker 3:

YAML

search:  
  formats:  
    \- html  
    \- json  
server:  
  limiter: false \# Disabilita il limitatore di velocità per uso interno

Questa configurazione permette agli agenti di inviare query strutturate e ricevere risultati pronti per il parsing.8 SearXNG aggrega risultati da oltre 70 motori di ricerca, permettendo di filtrare per categorie specifiche come "it", "science" o "general", ottimizzando così la qualità dei documenti che finiranno nella cartella raw/ della wiki.3

### **Vantaggi rispetto ai Servizi Cloud**

L'integrazione locale di SearXNG offre un controllo granulare che i servizi SaaS come Tavily o Perplexity non possono eguagliare in termini di privacy e personalizzazione.3 Mentre Tavily è ottimizzato per fornire contenuti già estratti e pronti per l'LLM, SearXNG permette di gestire internamente la logica di estrazione, riducendo la dipendenza da API esterne e i relativi costi.11

| Criterio | SearXNG (Self-hosted) | Tavily / Perplexity API |
| :---- | :---- | :---- |
| **Costo** | Gratuito (solo hardware) | A consumo / Abbonamento |
| **Privacy** | Massima (nessun dato esterno) | Esposizione a terze parti |
| **Flessibilità** | 70+ motori configurabili | Indice proprietario chiuso |
| **Integrazione** | JSON API locale | API REST via Cloud |

L'utilizzo di SearXNG all'interno del Knowledge Genome permette di automatizzare la scoperta di nuovi documenti. Un workflow n8n può monitorare specifiche query e, in base ai risultati, scaricare PDF o convertire pagine HTML in Markdown pulito per l'ingestione immediata nella wiki.2

## **Meccanismi di Recupero: Il Ruolo di QMD**

Per la gestione della ricerca e del recupero all'interno di una wiki che può crescere fino a migliaia di file, la semplice ricerca testuale non è più sufficiente. L'architettura adotta qmd (Query Markdown Documents), un motore di ricerca on-device progettato specificamente per agenti AI che lavorano su repository Markdown.12

### **Pipeline di Ricerca Ibrida**

qmd implementa una pipeline di ricerca ibrida che combina tre approcci fondamentali per garantire la massima precisione e pertinenza dei risultati 12:

1. **Ricerca Lessicale BM25:** Un algoritmo di ranking classico che eccelle nel trovare corrispondenze esatte di parole chiave, essenziale per rintracciare nomi di entità o termini tecnici specifici.5  
2. **Ricerca Semantica Vectorial:** Utilizza modelli di embedding locali (tramite node-llama-cpp e formati GGUF) per comprendere il significato dietro le parole, permettendo di trovare concetti correlati anche in assenza di parole chiave identiche.  
3. **LLM Re-ranking:** I risultati ottenuti dai primi due metodi vengono filtrati e ordinati da un piccolo modello LLM locale, che valuta la pertinenza di ciascun frammento rispetto alla query dell'utente prima di presentarli all'agente di ragionamento.12

Questa combinazione, fusa tramite Reciprocal Rank Fusion (RRF), assicura che l'agente riceva solo le informazioni più rilevanti, minimizzando il "rumore" all'interno della finestra di contesto dell'LLM.

### **Integrazione del Protocollo MCP**

Un aspetto critico di qmd è la sua esposizione tramite il Model Context Protocol (MCP).12 Questo protocollo permette ad agenti come Claude Code di interagire direttamente con il motore di ricerca senza dover ricaricare continuamente il modello di embedding o reinizializzare l'indice.12 qmd può funzionare come un server HTTP a lunga durata, fornendo risposte quasi istantanee alle richieste di ricerca dell'agente, fattore cruciale per mantenere la fluidità dei flussi di lavoro interattivi.12  
qmd supporta anche la gestione del contesto gerarchico tramite il comando qmd context add, che consente di aggiungere descrizioni basate sulla struttura ad albero delle cartelle. Questo aiuta l'LLM a compiere scelte più informate durante la selezione dei documenti, comprendendo la posizione logica di una nota all'interno dell'intera gerarchia della conoscenza.12

## **Gestione dei Dati e Architettura Git Modulare**

Il Knowledge Genome non è un unico repository monolitico, ma una struttura organizzata in multi-sottomoduli Git.2 Questa scelta architettonica risponde a esigenze di scalabilità, privacy e automazione differenziata.

### **Struttura in Sottomoduli Forgejo**

Il sistema utilizza Forgejo (un fork di Gitea) ospitato sul nodo AMD per orchestrare diversi repository indipendenti sotto un unico repository "Master".2 Ogni sottomodulo rappresenta un dominio di conoscenza specifico:

* **genome-dev/**: Documentazione di sviluppo, TUI, framework come Angular.2  
* **genome-finance/**: Analisi di mercato e dati finanziari personali.2  
* **genome-homelab/**: Specifiche dell'architettura Keru, log di rete e configurazioni infrastrutturali.2  
* **core-karpathy/**: Logica di sistema e script di manutenzione upstream.2

Questo approccio permette il "Selective Syncing": un utente può decidere di clonare solo il sottomodulo relativo allo sviluppo sul proprio laptop per lavorare offline, senza dover scaricare l'intero archivio.2 Inoltre, ogni sottomodulo può avere webhook e azioni automatizzate indipendenti; ad esempio, l'aggiunta di un documento in genome-finance/raw attiverà un processo di indicizzazione specifico per quel dominio, evitando sprechi di risorse computazionali.2

### **Protocolli di Rete e Condivisione File: NFS vs SMB**

Nella comunicazione tra il nodo AMD (storage) e il nodo Intel (compute), la scelta del protocollo di file sharing è determinante per le prestazioni della wiki. L'analisi tecnica raccomanda l'uso di NFS anziché SMB.6  
Mentre SMB è il protocollo nativo di Windows e gestisce bene gli ambienti misti, NFS è profondamente integrato nel kernel Linux e offre prestazioni superiori per carichi di lavoro caratterizzati da un alto numero di piccoli file, tipici dei repository Git e delle note Markdown.6

| Caratteristica | NFS (Network File System) | SMB (Server Message Block) |
| :---- | :---- | :---- |
| **Performance** | Più veloce per piccoli file e metadati | Più lento per frequenti operazioni di seek |
| **Overhead** | Basso (integrato nel kernel) | Alto (protocollo più complesso) |
| **Permessi** | Gestione nativa UID/GID Linux | Spesso problematico con i bit sticky |
| **CPU Load** | Minimo sul server e sul client | Maggiore a causa del logging e dell'autenticazione |

L'uso di NFS permette alle VM di Proxmox di eseguire comandi Git e scansioni qmd sulla wiki residente sul nodo AMD con latenze quasi impercettibili, a patto di configurare correttamente i flag di mount come noatime per ridurre le scritture inutili.6

## **Automazione e Git Flow: Human-in-the-Loop**

La manutenzione della wiki non è affidata esclusivamente all'automazione selvaggia, ma segue un rigoroso Git Flow che integra la supervisione umana per garantire la qualità dei dati.2

### **Il Ruolo di n8n e delle Forgejo Actions**

Per gestire la logica dei workflow, l'architettura distingue tra compiti deterministici e compiti basati sul giudizio.15

1. **n8n (Workflow AI):** Utilizzato per i processi di ricerca complessi. Un agente n8n può interrogare SearXNG, decidere quali fonti sono pertinenti, scaricarle e preparare una bozza di integrazione per la wiki.15 n8n è ideale quando il percorso dell'automazione non è lineare e richiede un modello decisionale in tempo reale.15  
2. **Forgejo Actions (CI/CD):** Utilizzate per la manutenzione strutturale. Script di linting eseguiti come azioni Git controllano che ogni pagina abbia i metadati corretti, che non vi siano link interrotti e che la struttura del repository rispetti lo schema definito in CLAUDE.md.1

### **Ingestione e Micro-Commit**

Quando un nuovo documento entra nel sistema, l'agente AI (come DeepSeek-V4 o Claude) non modifica direttamente il ramo main. Viene creato un ramo dedicato (es. feat/ai-ingest-\[nome-doc\]).2 L'agente esegue una serie di micro-commit convenzionali mentre aggiorna le pagine correlate e inserisce i wikilink (\]).1 Questo processo di "cross-linking" automatico assicura che la wiki diventi un grafo densamente connesso.4 Una volta completata l'operazione, viene aperta una Pull Request su Forgejo, permettendo all'utente di revisionare le modifiche prima dell'integrazione finale.2  
Questo approccio risolve il problema della "manutenzione faticosa" che porta molti utenti ad abbandonare le wiki personali: l'LLM si occupa del lavoro di segreteria e bookkeeping (sintesi, collegamenti, aggiornamento indici), mentre l'utente rimane l'architetto decisionale.2

## **Integrità Strutturale e "Linting" della Conoscenza**

La qualità di una wiki LLM-driven dipende dalla sua coerenza interna. Karpathy suggerisce l'uso di "linting" strutturale per mantenere l'efficienza del sistema.1

### **Regole di Manutenzione e Confinamento del Contesto**

Per garantire che l'LLM possa ragionare efficacemente sulla wiki, vengono applicate diverse restrizioni tecniche:

* **Pagine Atomiche:** Ogni pagina è soggetta a un "soft cap" di 400 righe e un "hard cap" di 800 righe.1 Questo garantisce che il contenuto di una singola pagina possa sempre rientrare nella finestra di contesto del modello senza perdita di attenzione.1  
* **YAML Frontmatter Obbligatorio:** Ogni file deve includere metadati come type, tags e updated. Questo permette a qmd di filtrare i documenti prima di leggere il corpo del testo, accelerando le operazioni di ricerca e riducendo il consumo di token.1  
* **Gestione delle Immagini e Asset:** Gli asset locali sono gestiti direttamente nel repository Git, permettendo all'LLM di referenziarli tramite percorsi relativi e assicurando che la wiki sia completamente autosufficiente.2

Il processo di linting identifica periodicamente le "pagine orfane" (pagine prive di link in entrata), i link interrotti e le contraddizioni logiche tra diverse sintesi.1 Quando viene rilevata una discrepanza, il sistema genera un task nel log.md della wiki, segnalando all'agente o all'utente la necessità di una riconciliazione manuale o assistita.2

## **Analisi delle Prestazioni e Scalabilità**

L'architettura distribuita è progettata per scalare man mano che la base di conoscenza si espande. L'uso combinato di hardware AMD e Intel offre percorsi di aggiornamento indipendenti.

### **Efficienza del Recupero e Modelli Locali**

L'implementazione di qmd su modelli GGUF locali permette di mantenere la privacy totale pur offrendo capacità di ricerca semantica avanzata.12 La velocità di indicizzazione è ottimizzata dall'array RAID 1 del nodo AMD, che gestisce le letture parallele necessarie per generare gli embedding di centinaia di file simultaneamente.2

| Metrica di Performance | Obiettivo Tecnico | Soluzione Implementativa |
| :---- | :---- | :---- |
| **Latenza di Ricerca** | \< 500ms per query ibrida | qmd con caching e RRF locale |
| **Throughput di Ingestione** | 10+ fonti/ora con sintesi | Pipeline distribuita n8n/Forgejo |
| **Integrità del Filesystem** | 99.9% di consistenza Git | RAID 1 \+ Backup PBS (Proxmox) |
| **Efficienza Rete** | 2.5 Gb/s di backbone | Switch dedicato VLAN 10 |

Man mano che la wiki supera le centinaia di pagine, l'architettura supporta lo sharding degli indici.1 Questo significa che qmd può suddividere la ricerca su diversi sottorepository, limitando la scansione solo alle aree tematiche pertinenti alla query, mantenendo le prestazioni costanti anche con migliaia di documenti.1

### **Sicurezza e Accesso Remoto**

Sebbene l'intero sistema risieda localmente, l'accessibilità è garantita in modo sicuro. L'accesso SSH e web ai nodi avviene tramite Cloudflare Tunnels o VPN Headscale, proteggendo la wiki da attacchi esterni senza la necessità di aprire porte sul router domestico.2 All'interno della rete locale, il traffico è segregato in una VLAN dedicata (VLAN 10), isolando i dati della wiki da altri dispositivi IoT potenzialmente meno sicuri.2

## **Conclusioni Tecniche e Prospettive Evolutive**

L'architettura analizzata rappresenta una soluzione d'avanguardia per la gestione della conoscenza nell'era degli agenti AI. Il Knowledge Genome non è semplicemente un database, ma un organismo informativo che vive e cresce attraverso la sintesi continua.2 La distribuzione tra un nodo AMD focalizzato sullo storage e un nodo Intel dedicato al compute massimizza l'efficienza hardware, mentre l'integrazione di strumenti come qmd e SearXNG fornisce all'LLM i sensi necessari per esplorare e organizzare il mondo dell'informazione in modo autonomo ma controllato.2  
Questa struttura risolve i colli di bottiglia critici della RAG tradizionale fornendo persistenza, coerenza e accumulo di valore nel tempo.2 Il passaggio a un modello in cui l'LLM "programma" la wiki in Markdown garantisce la longevità dei dati, rendendo la conoscenza indipendente dai singoli modelli linguistici o dai fornitori di software.17 In definitiva, il Knowledge Genome in ambiente homelab ibrido trasforma il server domestico in un vero e proprio "Memex" moderno, capace di supportare la ricerca profonda e lo sviluppo intellettuale attraverso un'infrastruttura solida, privata e scalabile.

#### **Bibliografia**

1. Turned Andrej Karpathy's "LLM Wiki" gist into a Claude Code plugin. Also works in Codex, OpenCode, Cursor, Gemini CLI, Pi, and OpenClaw. \- Reddit, accesso eseguito il giorno maggio 6, 2026, [https://www.reddit.com/r/ClaudeCode/comments/1sm374u/turned\_andrej\_karpathys\_llm\_wiki\_gist\_into\_a/](https://www.reddit.com/r/ClaudeCode/comments/1sm374u/turned_andrej_karpathys_llm_wiki_gist_into_a/)  
2. llm-wiki.md  
3. OpenClaw SearXNG Setup — Free Self-Hosted Search for AI Agents, accesso eseguito il giorno maggio 6, 2026, [https://openclawlaunch.com/guides/openclaw-searxng](https://openclawlaunch.com/guides/openclaw-searxng)  
4. Andrej Karpathy's LLM Wiki: Create your own knowledge base | by Urvil Joshi \- Medium, accesso eseguito il giorno maggio 6, 2026, [https://medium.com/@urvvil08/andrej-karpathys-llm-wiki-create-your-own-knowledge-base-8779014accd5](https://medium.com/@urvvil08/andrej-karpathys-llm-wiki-create-your-own-knowledge-base-8779014accd5)  
5. Karpathy's LLM Wiki: The Complete Guide to His Idea File \- Antigravity Codes, accesso eseguito il giorno maggio 6, 2026, [https://antigravity.codes/blog/karpathy-llm-wiki-idea-file](https://antigravity.codes/blog/karpathy-llm-wiki-idea-file)  
6. NFS vs SMB for Plex & Jellyfin: Which Is Faster? \- DiyMediaServer, accesso eseguito il giorno maggio 6, 2026, [https://diymediaserver.com/post/nfs-smb/](https://diymediaserver.com/post/nfs-smb/)  
7. Eternal Question: NFS or SMB storage \- Proxmox Support Forum, accesso eseguito il giorno maggio 6, 2026, [https://forum.proxmox.com/threads/eternal-question-nfs-or-smb-storage.159665/](https://forum.proxmox.com/threads/eternal-question-nfs-or-smb-storage.159665/)  
8. searxng | Skills Marketplace \- LobeHub, accesso eseguito il giorno maggio 6, 2026, [https://lobehub.com/skills/openclaw-skills-searxng-self-hosted](https://lobehub.com/skills/openclaw-skills-searxng-self-hosted)  
9. SearXNG Search \- liteLLM, accesso eseguito il giorno maggio 6, 2026, [https://docs.litellm.ai/docs/search/searxng](https://docs.litellm.ai/docs/search/searxng)  
10. SearXNG | FlowiseAI, accesso eseguito il giorno maggio 6, 2026, [https://docs.flowiseai.com/integrations/langchain/tools/searxng](https://docs.flowiseai.com/integrations/langchain/tools/searxng)  
11. Perplexity Search API vs. Tavily: RAG & Agent Choice 2025 \- AlphaCorp AI, accesso eseguito il giorno maggio 6, 2026, [https://alphacorp.ai/blog/perplexity-search-api-vs-tavily-the-better-choice-for-rag-and-agents-in-2025](https://alphacorp.ai/blog/perplexity-search-api-vs-tavily-the-better-choice-for-rag-and-agents-in-2025)  
12. GitHub \- tobi/qmd: mini cli search engine for your docs, knowledge ..., accesso eseguito il giorno maggio 6, 2026, [https://github.com/tobi/qmd](https://github.com/tobi/qmd)  
13. tobi-qmd \- Claude Code Plugin | ClaudePluginHub, accesso eseguito il giorno maggio 6, 2026, [https://www.claudepluginhub.com/plugins/tobi-qmd](https://www.claudepluginhub.com/plugins/tobi-qmd)  
14. Pushing to a Git repository on an NFS share fails \- Stack Overflow, accesso eseguito il giorno maggio 6, 2026, [https://stackoverflow.com/questions/4675587/pushing-to-a-git-repository-on-an-nfs-share-fails](https://stackoverflow.com/questions/4675587/pushing-to-a-git-repository-on-an-nfs-share-fails)  
15. Trying to understand the difference between n8n automations and local agents automations (claude, codex..) \- Reddit, accesso eseguito il giorno maggio 6, 2026, [https://www.reddit.com/r/n8n/comments/1t3rlts/trying\_to\_understand\_the\_difference\_between\_n8n/](https://www.reddit.com/r/n8n/comments/1t3rlts/trying_to_understand_the_difference_between_n8n/)  
16. n8n vs Make: Are No-Code Workflow Automations as Efficient as Code-Based Frameworks? \- ZenML Blog, accesso eseguito il giorno maggio 6, 2026, [https://www.zenml.io/blog/n8n-vs-make](https://www.zenml.io/blog/n8n-vs-make)  
17. What Is Andrej Karpathy's LLM Wiki? How to Build a Personal Knowledge Base With Claude Code | MindStudio, accesso eseguito il giorno maggio 6, 2026, [https://www.mindstudio.ai/blog/andrej-karpathy-llm-wiki-knowledge-base-claude-code](https://www.mindstudio.ai/blog/andrej-karpathy-llm-wiki-knowledge-base-claude-code)