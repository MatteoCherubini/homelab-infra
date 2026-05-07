# **Architettura di Sicurezza per Personal Genome Repository: Implementazione di Git-Crypt e Iniezione di Segreti a Runtime per Large Language Models Locali**

L'evoluzione della gestione della conoscenza personale attraverso l'integrazione di Large Language Models (LLM) locali ha introdotto una sfida fondamentale nella progettazione dei repository di dati: la necessità di bilanciare la collaborazione aperta con la riservatezza assoluta dei dati personali. Nel contesto di un sistema "genome" che aggrega articoli, trascrizioni e dati grezzi per alimentare un agente AI, emerge l'esigenza di una struttura ibrida. Tale struttura deve consentire ai collaboratori interni di operare sulle componenti pubbliche o condivise, mantenendo al contempo una barriera crittografica invalicabile sui dati sensibili destinati esclusivamente al consumo da parte dell'LLM dell'utente.

## **Meccanismi Crittografici e Trasparenza Operativa in Git**

L'adozione di un sistema di cifratura all'interno di un flusso di lavoro basato su Git non deve compromettere l'esperienza utente né interrompere la continuità operativa di strumenti come Obsidian o agenti AI. La soluzione identificata come ottimale per questo scenario è git-crypt, uno strumento che si discosta dai sistemi basati su password statiche per abbracciare un modello di cifratura trasparente integrato direttamente nel "plumbing" di Git.1

### **Il Funzionamento del Filtro Git-Crypt**

Il cuore tecnologico di git-crypt risiede nella sua capacità di utilizzare gli attributi di Git per automatizzare i processi di cifratura e decifratura. Attraverso la configurazione del file .gitattributes, è possibile definire regole granulari che istruiscono Git ad applicare i filtri di git-crypt solo a determinate directory o pattern di file.1 Quando un file viene aggiunto all'area di staging, Git applica un filtro di "pulizia" (clean filter) che cifra il contenuto prima che venga memorizzato nel database degli oggetti. Al contrario, quando un file viene estratto nel working directory, viene applicato un filtro di "smudging" che decifra il file in modo che sia leggibile dalle applicazioni locali.2  
Questo approccio garantisce che, sul server remoto (come Forgejo), i file sensibili esistano solo come blob binari cifrati utilizzando l'algoritmo $AES-256-CTR$.1 Un collaboratore che clona il repository senza possedere la chiave crittografica vedrà correttamente la struttura delle cartelle e i file pubblici, ma i contenuti all'interno delle cartelle private risulteranno illeggibili. Al contrario, l'utente autorizzato che sblocca il repository tramite il comando git-crypt unlock vedrà i file come normali documenti Markdown o file di testo, rendendoli immediatamente disponibili per l'LLM locale.2

### **Confronto tra Metodologie di Gestione dei Segreti**

Esistono diverse alternative a git-crypt, ciascuna con punti di forza e debolezze specifici. La scelta dello strumento corretto dipende dal modello di minaccia e dalla natura dei dati da proteggere.

| Strumento | Algoritmo Principale | Tipo di Cifratura | Gestione Accessi | Integrazione Cloud |
| :---- | :---- | :---- | :---- | :---- |
| **git-crypt** | $AES-256-CTR$ | Intero file | Repository-level | Limitata |
| **SOPS** | $AES-256-GCM$ | Parziale (Key-Value) | File-level | Alta (AWS, GCP, Vault) |
| **transcrypt** | $AES-256-CBC$ | Intero file | Repository-level | Limitata |
| **git-secret** | $AES-256-OCB$ | Intero file | GPG-based | Nulla |

Mentre SOPS (Secrets OPerationS) è eccellente per file di configurazione YAML o JSON dove solo alcuni valori devono essere nascosti, git-crypt risulta più idoneo per repository di tipo "genome" dove intere directory di documenti Markdown devono essere protette mantenendo la trasparenza per l'agente AI.1 SOPS richiede comandi espliciti per la modifica dei file, il che aggiungerebbe attrito in un flusso di lavoro basato su Obsidian, dove la scrittura e la lettura devono essere fluide.2

## **Architettura del Repository Ibrido**

La progettazione logica del repository deve riflettere la distinzione tra dati condivisi e dati privati. Una struttura ben definita permette non solo una corretta applicazione delle regole di git-crypt, ma facilita anche il compito dell'LLM nel distinguere il contesto pubblico da quello personale.

### **Struttura delle Directory e Regole di Visibilità**

La convenzione strutturale proposta organizza i dati in due rami principali: raw/ per i dati non elaborati e wiki/ per la conoscenza sintetizzata. All'interno di ciascuno, una sottodirectory private/ è soggetta a cifratura obbligatoria.

| Directory | Descrizione | Visibilità Collaboratori | Trattamento LLM |
| :---- | :---- | :---- | :---- |
| raw/articles/ | Ricerche web, PDF, articoli pubblici | In chiaro (Accessibile) | Contesto Generale |
| raw/transcripts/ | Trascrizioni di riunioni o video pubblici | In chiaro (Accessibile) | Contesto Generale |
| raw/private/ | Diari, log personali, corrispondenza | Cifrato (Inaccessibile) | Contesto Personale |
| wiki/private/ | Sintesi di dati sensibili, genome personale | Cifrato (Inaccessibile) | Contesto Personale |
| .gitattributes | Configurazioni dei filtri crittografici | In chiaro (Visibile) | Metadata di Sistema |

L'inclusione di wiki/private/ è di vitale importanza. Mentre la cartella raw/ contiene dati grezzi che potrebbero essere voluminosi e disordinati, la wiki/ privata ospita le analisi e le riflessioni che l'agente AI ha già distillato. Questa gerarchia permette una Retrieval-Augmented Generation (RAG) più efficiente, poiché l'agente può cercare prima nelle sintesi e solo successivamente nei dati grezzi se necessario.2

### **Integrità e Degradazione Graziosa**

Un vantaggio fondamentale di questa architettura è la cosiddetta "degradazione graziosa". Gli sviluppatori o i collaboratori che non hanno accesso alla chiave possono continuare a contribuire al codice o alla documentazione pubblica senza interferire con i file cifrati.4 Git gestisce i file cifrati come blob binari opachi; pertanto, un collaboratore può persino spostare o rinominare tali file e Git preserverà lo stato cifrato nel commit successivo, a patto che le regole in .gitattributes rimangano coerenti.4 Tuttavia, la sicurezza del sistema dipende interamente dall'integrità del file .gitattributes. Se un utente malintenzionato o un collaboratore inesperto dovesse modificare o rimuovere le regole di cifratura, i file aggiunti successivamente verrebbero inviati in chiaro. È pertanto raccomandato l'uso di tag firmati e revisioni rigorose su questo file critico.3

## **Gestione delle Chiavi e Vulnerabilità del Server AI**

L'aspetto più critico dell'intera implementazione riguarda la persistenza della chiave crittografica. Per consentire all'LLM di accedere ai dati in raw/private/, il repository deve essere sbloccato sull'host in cui gira l'agente. Questo introduce un rischio: se la chiave simmetrica è memorizzata sul disco della macchina virtuale (VM) che ospita l'AI o su un server di gestione come Nexus, una compromissione di tale macchina esporrebbe l'intero archivio privato.8

### **Il Nodo della Persistenza su Disco**

In uno scenario standard, git-crypt memorizza la chiave sbloccata all'interno della directory .git/ del repository locale. Se un attaccante ottiene l'accesso root alla VM AI, può facilmente estrarre questa chiave o semplicemente leggere i file già decifrati nel file system. Questo significa che il vantaggio della cifratura è nullo contro un attacco interno al server, rimanendo efficace solo contro fughe di dati dal server remoto Forgejo o verso collaboratori esterni.2  
Le implicazioni di sicurezza variano in base all'infrastruttura. Se si utilizza un sistema come NixOS, è necessario prestare particolare attenzione poiché i file aggiunti allo store di Nix (/nix/store) sono spesso leggibili da tutti gli utenti del sistema, annullando di fatto le protezioni di isolamento degli utenti fornite da systemd.8 Pertanto, la gestione della chiave deve essere elevata a un livello superiore di astrazione.

### **Iniezione dei Segreti a Runtime tramite Vaultwarden**

Per mitigare il rischio di persistenza su disco, la soluzione più robusta consiste nell'estrarre la chiave da un vault (come Vaultwarden o Bitwarden Secrets Manager) solo nel momento in cui è necessaria, mantenendola esclusivamente in memoria o in partizioni temporanee volatili. L'utilizzo della Bitwarden Secrets Manager CLI (bws) permette di automatizzare questo processo in modo sicuro.9  
Il flusso di lavoro avanzato prevede i seguenti passaggi:

1. L'agente AI o uno script di orchestrazione richiede il segreto tramite bws secret get.  
2. Il segreto viene passato a git-crypt unlock senza creare un file fisico sul disco persistente.  
3. Si utilizza la sostituzione di processo di Bash per fornire la chiave a git-crypt come se fosse un file.11

Bash

git-crypt unlock \<(bws secret get "ID\_DELLA\_CHIAVE" | jq \-r '.value')

Questa tecnica sfrutta i descrittori di file temporanei forniti dal kernel Linux, garantendo che la chiave non venga mai scritta su un supporto non volatile.11 Una volta completata l'operazione di sblocco, la chiave risiede nella memoria RAM del processo. Per una sicurezza totale, la directory di lavoro dell'agente potrebbe essere montata su un volume tmpfs, assicurando che ogni traccia dei dati decifrati scompaia al riavvio del server.8

## **Il Controllo dell'Esposizione dei Dati: Il Toggle AGENTS.md**

Oltre alla protezione crittografica, è necessario un meccanismo logico per decidere quando l'LLM debba effettivamente utilizzare i dati privati. Non tutte le sessioni di lavoro richiedono l'accesso alla sfera personale dell'utente; ad esempio, se si utilizza l'agente per generare un report professionale da condividere, includere dati privati nel contesto potrebbe portare a allucinazioni o inclusioni indesiderate di informazioni sensibili nel testo finale.

### **Protocollo di Configurazione della Sessione**

La soluzione risiede in una convenzione di prompt gestita tramite un file di configurazione chiamato AGENTS.md. Questo file funge da "manuale di istruzioni" per l'agente AI, definendo i confini del suo raggio d'azione. Una variabile specifica, PRIVATE\_CONTEXT, agisce come un toggle logico che l'agente legge all'inizio di ogni interazione.

| Stato | Comportamento dell'Agente | Caso d'Uso Tipico |
| :---- | :---- | :---- |
| PRIVATE\_CONTEXT: disabled | L'agente ignora totalmente le directory raw/private/ e wiki/private/. | Lavoro collaborativo, sessioni condivise, uso di modelli cloud. |
| PRIVATE\_CONTEXT: enabled | L'agente indicizza e interroga i dati privati per analisi personali. | Auto-compilazione di diari, analisi finanziarie, genome research. |

Questo meccanismo non è un blocco tecnico nel senso stretto della crittografia, ma una direttiva di sistema. Poiché l'agente locale ha accesso fisico ai file decifrati (una volta sbloccato il repository), la responsabilità di non "leggere" tali file viene delegata alla logica del modello stesso, istruito dal sistema di orchestratore. È una forma di governance basata sull'intento umano, fondamentale per mantenere la flessibilità del sistema senza compromettere la privacy per errore.14

### **Multi-tenancy e Filtraggio dei Metadati**

In architetture più complesse, dove più agenti AI operano sullo stesso database vettoriale (RAG), il toggle può essere implementato a livello di filtraggio dei metadati. Durante la fase di ingestione, ogni chunk di testo proveniente da cartelle private viene marcato con un tag di metadati visibility: private. Quando il toggle in AGENTS.md è disabilitato, il client di recupero (retrieval client) aggiunge automaticamente un filtro alle query vettoriali per escludere tutti i chunk con tale tag.7 Questo garantisce che, anche se i dati sono stati indicizzati nel database, essi rimangano invisibili al modello a meno che non vi sia un'esplicita autorizzazione.7

## **Automazione della Sicurezza e Prevenzione delle Fughe**

Uno dei pericoli maggiori nell'uso di git-crypt è la possibilità di inviare accidentalmente dati in chiaro a causa di una configurazione errata o di una dimenticanza. Se un utente aggiunge un file in raw/private/ prima di aver configurato correttamente il file .gitattributes, Git tratterà quel file come testo normale e lo caricherà sul server Forgejo senza cifratura.3

### **Implementazione di Pre-commit Hooks**

Per prevenire questi errori umani, è indispensabile l'uso di Git Hooks, specificamente il hook di pre-commit. Questo script viene eseguito localmente prima di ogni commit e può essere configurato per bloccare l'azione se vengono rilevate anomalie.15  
Un pre-commit hook efficace per questo scenario dovrebbe:

1. Analizzare la lista dei file pronti per il commit (staged files).  
2. Verificare se qualcuno di questi file rientra nei pattern definiti come privati (es. raw/private/).  
3. Eseguire il comando git-crypt status per verificare lo stato di cifratura di tali file.16  
4. Se un file destinato alla cartella privata è marcato come "non cifrato", lo script deve interrompere il commit e avvisare l'utente con un messaggio di errore critico.16

Questo approccio "fail-safe" trasforma la sicurezza da una scelta manuale a un processo automatizzato obbligatorio, riducendo drasticamente la probabilità di leak accidentali verso i collaboratori o il server remoto.17

### **Simulazione dello Stato "Locked"**

Un'altra buona pratica consiste nel verificare periodicamente come il repository appare a un utente non autorizzato. Il comando git-crypt lock permette di riportare temporaneamente i file locali allo stato cifrato (binario).2 Eseguire questo comando e tentare di leggere un file tramite terminale o Obsidian è un test empirico fondamentale per confermare che la cifratura stia effettivamente funzionando e che nessun dato sensibile sia rimasto accidentalmente in chiaro nel database di Git.2 Dopo il test, il repository può essere sbloccato nuovamente utilizzando la chiave conservata nel vault.2

## **Integrazione con l'Ecosistema AI locale**

L'obiettivo finale di questa architettura è servire l'LLM locale in modo che possa agire come un vero assistente personale. L'agente, tipicamente orchestrato tramite Python o Node.js, deve essere configurato per onorare la struttura del repository.

### **Consumo dei Dati da parte dell'Agente**

Quando l'agente viene avviato, esso esegue una scansione della directory radice del genome. Se rileva che il repository è bloccato (ovvero i file in raw/private/ iniziano con l'header GITCRYPT), l'agente può segnalare all'utente la necessità di sblocco o tentare un'autenticazione automatica tramite la Bitwarden CLI se le credenziali di sistema lo permettono.19  
Il processo di indicizzazione per la RAG deve essere differenziato:

* **Dati Pubblici**: Possono essere indicizzati in un indice vettoriale globale, accessibile a qualsiasi configurazione dell'agente.  
* **Dati Privati**: Devono essere indicizzati in un indice separato o protetti da rigorosi filtri di metadati basati sulla variabile PRIVATE\_CONTEXT.7

Questa separazione previene la contaminazione del modello. Senza di essa, anche se l'agente riceve l'ordine di ignorare i dati privati, tali informazioni potrebbero influenzare le risposte a causa della loro presenza nello spazio vettoriale dei risultati più simili.7

### **Ruolo di Obsidian e delle Applicazioni GUI**

Mentre l'agente AI legge i dati programmaticamente, l'utente interagisce con essi tramite Obsidian. git-crypt funziona in modo trasparente per Obsidian, che vede i file decifrati nel file system. Tuttavia, è importante notare che alcune interfacce grafiche di Git (come SourceTree o alcuni plugin IDE) potrebbero non supportare correttamente i filtri di git-crypt, visualizzando i file come binari anche quando dovrebbero essere decifrati.3 Per questo motivo, si raccomanda che le operazioni di sblocco e commit vengano eseguite tramite riga di comando o script di automazione ben testati.3

## **Analisi delle Prestazioni e Scalabilità**

L'uso di cifratura trasparente introduce un overhead computazionale, specialmente durante le operazioni di git checkout o git commit su grandi volumi di dati. $AES-256-CTR$ è un algoritmo molto veloce, ma la necessità di processare ogni file attraverso OpenSSL può rallentare l'esperienza se il repository contiene decine di migliaia di piccoli file Markdown.1

| Operazione | Impatto Prestazionale | Mitigazione |
| :---- | :---- | :---- |
| **Commit** | Medio-Alto (Cifratura di ogni file) | Utilizzo di commit incrementali frequenti |
| **Checkout/Pull** | Medio (Decifratura dei nuovi blob) | Ottimizzazione delle dimensioni dei file |
| **RAG Ingestion** | Basso (I file sono già decifrati su disco) | Nessuna (Processo standard) |
| **LLM Inference** | Nullo | Nessuna |

Per repository di dimensioni massicce, potrebbe essere utile suddividere i dati privati in sottomoduli Git separati, ciascuno con la propria chiave di git-crypt. Questo permetterebbe di sbloccare selettivamente solo le parti del genome necessarie per una determinata attività, migliorando sia la sicurezza che le prestazioni del sistema.

## **Considerazioni sulla Gestione Collaborativa**

In un ambiente con collaboratori interni, la trasparenza di git-crypt deve essere gestita con attenzione. Se un collaboratore deve avere accesso a una parte dei dati privati, il proprietario del repository può aggiungere la sua chiave GPG.3 Questo crea un sistema multi-utente dove non è necessario condividere una singola password simmetrica, ma ogni utente autorizzato usa la propria chiave privata per sbloccare lo stesso set di segreti.3  
Tuttavia, la revoca dell'accesso rimane il punto debole di questo modello. Se un collaboratore lascia il progetto, rimuovere la sua chiave GPG dal repository impedisce solo che riceva aggiornamenti futuri in modo leggibile. Per revocare completamente l'accesso ai dati storici, è necessario generare una nuova chiave simmetrica, re-criptare tutti i file e distribuire la nuova chiave solo agli utenti rimanenti.6 In un contesto di dati personali, la soluzione più semplice rimane non concedere mai l'accesso alla cartella private/ a terzi, mantenendo la chiave simmetrica come un segreto esclusivo del proprietario e del suo agente AI.

## **Conclusione**

L'implementazione di cartelle private cifrate tramite git-crypt all'interno di un repository genome collaborativo rappresenta una soluzione tecnica matura e bilanciata. La forza di questo approccio risiede nella sua invisibilità operativa: una volta configurato, il sistema permette all'LLM locale e ad Obsidian di operare su dati sensibili come se fossero in chiaro, mentre garantisce che tali dati rimangano inaccessibili su server remoti e per collaboratori non autorizzati.  
Il successo di questa architettura dipende dall'adozione di rigorose pratiche di gestione delle chiavi. L'eliminazione della persistenza della chiave sul disco del server AI, attraverso l'uso di vault e iniezione a runtime via Bitwarden CLI e process substitution, eleva la sicurezza verso un modello Zero-Trust. Parallelamente, l'uso di convenzioni logiche come il toggle PRIVATE\_CONTEXT nel file AGENTS.md assicura che l'utente mantenga sempre il controllo decisionale su quali informazioni debbano fluire nel contesto dell'intelligenza artificiale.  
Questa infrastruttura trasforma il repository da un semplice contenitore di file a un ambiente di conoscenza dinamico e sicuro, dove la collaborazione aperta e la massima privacy personale non sono più in conflitto, ma coesistono come pilastri fondamentali di un ecosistema AI moderno e sovrano. L'adozione di queste tecniche permette di costruire un "Personal Genome" che sia al contempo uno strumento di lavoro condiviso e un archivio inviolabile della propria vita digitale.

#### **Bibliografia**

1. Securely storing secrets in Git. Secrets management and secure ..., accesso eseguito il giorno maggio 7, 2026, [https://medium.com/@slimm609/securely-storing-secrets-in-git-542771d3ed8c](https://medium.com/@slimm609/securely-storing-secrets-in-git-542771d3ed8c)  
2. How to Manage Your Secrets with git-crypt \- DEV Community, accesso eseguito il giorno maggio 7, 2026, [https://dev.to/heroku/how-to-manage-your-secrets-with-git-crypt-56ih](https://dev.to/heroku/how-to-manage-your-secrets-with-git-crypt-56ih)  
3. git-crypt setup guide · Francesco Pira, accesso eseguito il giorno maggio 7, 2026, [https://fpira.com/blog/2021/11/git-crypt-setup-guide](https://fpira.com/blog/2021/11/git-crypt-setup-guide)  
4. Using Git-crypt to Protect Sensitive Data \- Sebastien Varrette, PhD., accesso eseguito il giorno maggio 7, 2026, [http://varrette.gforge.uni.lu/blog/2018/12/07/using-git-crypt-to-protect-sensitive-data/](http://varrette.gforge.uni.lu/blog/2018/12/07/using-git-crypt-to-protect-sensitive-data/)  
5. Managing Secrets With git-crypt \- DZone, accesso eseguito il giorno maggio 7, 2026, [https://dzone.com/articles/managing-secrets-with-git-crypt](https://dzone.com/articles/managing-secrets-with-git-crypt)  
6. Lightweight Secrets Management Tools For Git Encryption \- Austin ..., accesso eseguito il giorno maggio 7, 2026, [https://austindewey.com/2019/01/28/lightweight-secrets-management-tools-for-git-encryption/](https://austindewey.com/2019/01/28/lightweight-secrets-management-tools-for-git-encryption/)  
7. Real-time Retrieval for RAG on Social Media Data ... \- Medium, accesso eseguito il giorno maggio 7, 2026, [https://medium.com/decodingai/a-real-time-retrieval-system-for-rag-on-social-media-data-9cc01d50a2a0](https://medium.com/decodingai/a-real-time-retrieval-system-for-rag-on-social-media-data-9cc01d50a2a0)  
8. Handling Secrets in NixOS: An Overview (git-crypt, agenix, sops-nix ..., accesso eseguito il giorno maggio 7, 2026, [https://discourse.nixos.org/t/handling-secrets-in-nixos-an-overview-git-crypt-agenix-sops-nix-and-when-to-use-them/35462](https://discourse.nixos.org/t/handling-secrets-in-nixos-an-overview-git-crypt-agenix-sops-nix-and-when-to-use-them/35462)  
9. Developer Quick Start \- Bitwarden, accesso eseguito il giorno maggio 7, 2026, [https://bitwarden.com/help/developer-quick-start/](https://bitwarden.com/help/developer-quick-start/)  
10. Secrets Manager CLI \- Bitwarden, accesso eseguito il giorno maggio 7, 2026, [https://bitwarden.com/help/secrets-manager-cli/](https://bitwarden.com/help/secrets-manager-cli/)  
11. Handy Bash feature: Process Substitution | by Joe Walnes \- Medium, accesso eseguito il giorno maggio 7, 2026, [https://medium.com/@joewalnes/handy-bash-feature-process-substitution-8eb6dce68133](https://medium.com/@joewalnes/handy-bash-feature-process-substitution-8eb6dce68133)  
12. How to Handle Process Substitution in Bash \- OneUptime, accesso eseguito il giorno maggio 7, 2026, [https://oneuptime.com/blog/post/2026-01-24-bash-process-substitution/view](https://oneuptime.com/blog/post/2026-01-24-bash-process-substitution/view)  
13. In bash, is it generally better to use process substitution or pipelines \- Stack Overflow, accesso eseguito il giorno maggio 7, 2026, [https://stackoverflow.com/questions/48485029/in-bash-is-it-generally-better-to-use-process-substitution-or-pipelines](https://stackoverflow.com/questions/48485029/in-bash-is-it-generally-better-to-use-process-substitution-or-pipelines)  
14. Show HN: Lockenv – Simple encrypted secrets storage for Git | Hacker News, accesso eseguito il giorno maggio 7, 2026, [https://news.ycombinator.com/item?id=46189480](https://news.ycombinator.com/item?id=46189480)  
15. Stop Committing Mistakes: Catch Issues Early with Git Pre-Commit Hooks \- Medium, accesso eseguito il giorno maggio 7, 2026, [https://medium.com/@ariifischbein/stop-committing-mistakes-catch-issues-early-with-git-pre-commit-hooks-c88e7393325c](https://medium.com/@ariifischbein/stop-committing-mistakes-catch-issues-early-with-git-pre-commit-hooks-c88e7393325c)  
16. Pre-commit hook to avoid accidentally adding unencrypted files · Issue \#45 · AGWA/git-crypt, accesso eseguito il giorno maggio 7, 2026, [https://github.com/AGWA/git-crypt/issues/45](https://github.com/AGWA/git-crypt/issues/45)  
17. How to Set Up SOPS Pre-Commit Hooks for Flux Repositories \- OneUptime, accesso eseguito il giorno maggio 7, 2026, [https://oneuptime.com/blog/post/2026-03-13-how-to-set-up-sops-pre-commit-hooks-for-flux-repositories/view](https://oneuptime.com/blog/post/2026-03-13-how-to-set-up-sops-pre-commit-hooks-for-flux-repositories/view)  
18. A git hook to prevent pushes with untracked source files \- Milian Wolff, accesso eseguito il giorno maggio 7, 2026, [https://milianw.de/code-snippets/a-git-hook-to-prevent-pushes-with-untracked-source-files.html](https://milianw.de/code-snippets/a-git-hook-to-prevent-pushes-with-untracked-source-files.html)  
19. Bitwarden \- chezmoi, accesso eseguito il giorno maggio 7, 2026, [https://www.chezmoi.io/user-guide/password-managers/bitwarden/](https://www.chezmoi.io/user-guide/password-managers/bitwarden/)