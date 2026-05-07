#!/usr/bin/env bash
# =============================================================================
# setup-knowledge-genome.sh
# Crea l'intera struttura del Knowledge Genome su Forgejo (keruhomelab.com)
#
# PREREQUISITI:
#   - git installato in locale
#   - curl installato in locale
#   - Accesso a git.keruhomelab.com (LAN o tunnel Cloudflare)
#   - Un token Forgejo con permessi "repo" (Settings → Applications → Tokens)
#
# ESECUZIONE:
#   chmod +x setup-knowledge-genome.sh
#   FORGEJO_TOKEN="il_tuo_token" ./setup-knowledge-genome.sh
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURAZIONE — modifica solo questa sezione
# ---------------------------------------------------------------------------
FORGEJO_URL="https://git.keruhomelab.com"
FORGEJO_USER="keru"                           # il tuo username su Forgejo
FORGEJO_TOKEN="${FORGEJO_TOKEN:?Errore: esporta FORGEJO_TOKEN prima di eseguire}"
GIST_URL="https://gist.github.com/442a6bf555914893e9891c11519de94f.git"
WORK_DIR="${HOME}/knowledge-genome-setup"     # cartella di lavoro locale temporanea

# Nomi dei repository che verranno creati su Forgejo
MASTER_REPO="master-knowledge-genome"
GENOMES=("genome-dev" "genome-finance" "genome-homelab")

# ---------------------------------------------------------------------------
# COLORI PER OUTPUT
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
step()    { echo -e "\n${YELLOW}━━━ $* ━━━${NC}"; }

# ---------------------------------------------------------------------------
# FUNZIONE: crea un repository su Forgejo via API
# Uso: forgejo_create_repo <nome_repo> <descrizione> <privato: true|false>
# ---------------------------------------------------------------------------
forgejo_create_repo() {
  local name="$1" desc="$2" private="$3"
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${FORGEJO_URL}/api/v1/user/repos" \
    -H "Authorization: token ${FORGEJO_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"${name}\",
      \"description\": \"${desc}\",
      \"private\": ${private},
      \"auto_init\": false,
      \"default_branch\": \"main\"
    }")

  if [[ "$http_code" == "201" ]]; then
    success "Repository '${name}' creato su Forgejo."
  elif [[ "$http_code" == "409" ]]; then
    info "Repository '${name}' già esistente — skip creazione."
  else
    echo "Errore HTTP ${http_code} durante la creazione di '${name}'." >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# FUNZIONE: crea le directory e i file template di un genome
# Uso: scaffold_genome <path_locale>
# ---------------------------------------------------------------------------
scaffold_genome() {
  local base="$1"
  local name
  name=$(basename "$base")

  # Struttura directory
  mkdir -p \
    "${base}/raw/articles" \
    "${base}/raw/transcripts" \
    "${base}/raw/code-packs" \
    "${base}/raw/assets" \
    "${base}/wiki/sources" \
    "${base}/wiki/entities" \
    "${base}/wiki/concepts" \
    "${base}/wiki/queries"

  # .gitkeep per cartelle vuote (git non traccia cartelle vuote)
  for dir in \
    raw/articles raw/transcripts raw/code-packs raw/assets \
    wiki/sources wiki/entities wiki/concepts wiki/queries; do
    touch "${base}/${dir}/.gitkeep"
  done

  # wiki/index.md — catalogo master del genome
  cat > "${base}/wiki/index.md" << EOF
---
title: "Index — ${name}"
type: index
last_updated: $(date +%Y-%m-%d)
---

# Index: ${name}

Catalogo master di tutte le pagine del genome. Aggiornato dall'agente ad ogni ingestione.

## Fonti (sources/)
<!-- L'agente aggiunge qui ogni fonte ingerita -->

## Entità (entities/)
<!-- Persone, tool, organizzazioni -->

## Concetti (concepts/)
<!-- Teorie, pattern, architetture -->

## Query archiviate (queries/)
<!-- Risposte sintetizzate degne di essere conservate -->
EOF

  # wiki/log.md — registro append-only
  cat > "${base}/wiki/log.md" << EOF
---
title: "Log — ${name}"
type: log
---

# Log operativo: ${name}

Registro append-only di tutte le operazioni dell'agente.
Formato: \`## [YYYY-MM-DD] <operazione> | <titolo>\`

---

## [$(date +%Y-%m-%d)] init | Repository inizializzato
Struttura scaffold creata. Nessuna fonte ancora ingerita.
EOF

  # AGENTS.md — schema locale del genome (contratto con l'agente)
  cat > "${base}/AGENTS.md" << AGENTEOF
# Schema del Genome: ${name}

Questo file definisce le regole operative per l'agente che mantiene questo genome.
L'agente deve leggere questo file all'inizio di ogni sessione.

---

## Identità del Genome

- **Nome:** ${name}
- **Scopo:** <!-- descrivi l'ambito di conoscenza di questo genome -->
- **Proprietario:** ${FORGEJO_USER}

---

## Regole Fondamentali

1. **raw/ è sacra e immutabile.** L'agente può leggere raw/ ma non modificarne il contenuto.
2. **wiki/ è di proprietà dell'agente.** L'agente crea, aggiorna e collega le pagine in wiki/.
3. **Ogni operazione va registrata in wiki/log.md** nel formato: \`## [YYYY-MM-DD] <op> | <titolo>\`
4. **wiki/index.md va aggiornato ad ogni ingestione** con il link alla nuova pagina source.
5. **I commit seguono Conventional Commits:**
   - \`feat(wiki): add source page for <titolo>\`
   - \`fix(wiki): resolve contradiction in <concetto>\`
   - \`chore(wiki): lint — fix orphan pages\`

---

## Flusso di Ingestione (Ingest)

Quando viene aggiunto un file in raw/:

1. Leggi il documento.
2. Crea \`wiki/sources/<slug-titolo>.md\` con riassunto + punti chiave.
3. Identifica entità (persone, tool, organizzazioni) → aggiorna/crea pagine in \`wiki/entities/\`.
4. Identifica concetti (pattern, teorie, architetture) → aggiorna/crea pagine in \`wiki/concepts/\`.
5. Se una nuova info contraddice una esistente, aggiungi sezione **"Contraddizioni o Evoluzioni"** nella pagina del concetto — non cancellare il dato precedente.
6. Aggiorna \`wiki/index.md\`.
7. Appendi entry a \`wiki/log.md\`.
8. Commit atomico su branch \`feat/ai-ingest-<slug>\`.
9. Apri Pull Request su Forgejo per revisione umana.

---

## Flusso di Query

Quando l'utente fa una domanda:

1. Leggi \`wiki/index.md\` per individuare le pagine pertinenti.
2. Leggi le pagine rilevanti.
3. Sintetizza la risposta con citazioni (\[\[wikilink\]\]).
4. Se la risposta è di valore duraturo, proponi di salvarla in \`wiki/queries/<slug>.md\`.

---

## Flusso di Lint (Manutenzione)

Periodicamente:

1. Cerca pagine orfane (nessun link in entrata).
2. Cerca concetti duplicati da unificare.
3. Cerca termini menzionati più volte senza pagina dedicata.
4. Segnala affermazioni potenzialmente obsolete.
5. Controlla che ogni pagina abbia il frontmatter YAML corretto.

---

## Formato Frontmatter YAML

Ogni pagina wiki deve iniziare con:

\`\`\`yaml
---
title: "Titolo della pagina"
type: source | entity | concept | query
domain: ${name}
tags: []
confidence: high | medium | low
last_updated: YYYY-MM-DD
source_count: N   # solo per pagine concept/entity
---
\`\`\`
AGENTEOF

  # .gitignore del genome
  cat > "${base}/.gitignore" << 'GITEOF'
# File di sistema
.DS_Store
Thumbs.db

# Obsidian (solo la config è tracciata, non la cache)
.obsidian/workspace.json
.obsidian/workspace-mobile.json
.obsidian/cache

# File temporanei
*.tmp
*.bak
GITEOF

  success "Scaffold completato per: ${name}"
}

# =============================================================================
# INIZIO SCRIPT
# =============================================================================

step "1/6 — Preparazione ambiente locale"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"
info "Directory di lavoro: ${WORK_DIR}"

# =============================================================================
step "2/6 — Creazione repository su Forgejo"
# =============================================================================

# Repository master (pubblico: false — contiene riferimenti a finance, ecc.)
forgejo_create_repo \
  "${MASTER_REPO}" \
  "Master Knowledge Genome — archivio radice con sottomoduli per dominio" \
  "false"

# Repository genome (tutti privati per default)
forgejo_create_repo \
  "genome-dev" \
  "Knowledge Genome: Sviluppo Web, TUI, Angular, architetture software" \
  "false"

forgejo_create_repo \
  "genome-finance" \
  "Knowledge Genome: Finanza personale, investimenti, analisi di mercato" \
  "true"

forgejo_create_repo \
  "genome-homelab" \
  "Knowledge Genome: Infrastruttura Keru, configurazioni, log di rete" \
  "false"

# =============================================================================
step "3/6 — Scaffold e push dei genome-repo"
# =============================================================================

for genome in "${GENOMES[@]}"; do
  info "Inizializzo ${genome}..."
  mkdir -p "${WORK_DIR}/${genome}"
  cd "${WORK_DIR}/${genome}"

  git init -b main
  git remote add origin "${FORGEJO_URL}/${FORGEJO_USER}/${genome}.git"

  scaffold_genome "${WORK_DIR}/${genome}"

  git add .
  git commit -m "chore: initial scaffold for ${genome}"
  git push -u origin main

  success "${genome} pushato su Forgejo."
  cd "${WORK_DIR}"
done

# =============================================================================
step "4/6 — Inizializzazione master-knowledge-genome"
# =============================================================================

mkdir -p "${WORK_DIR}/${MASTER_REPO}"
cd "${WORK_DIR}/${MASTER_REPO}"
git init -b main
git remote add origin "${FORGEJO_URL}/${FORGEJO_USER}/${MASTER_REPO}.git"

# AGENTS.md globale del repository master
cat > AGENTS.md << 'EOF'
# Schema Globale: master-knowledge-genome

Questo file coordina tutti i genome-submodule del Knowledge Genome personale.

## Struttura

```
master-knowledge-genome/
├── core-karpathy/     ← submodule: pattern LLM Wiki di Karpathy (read-only)
├── genome-dev/        ← submodule: sviluppo web, TUI, Angular
├── genome-finance/    ← submodule: finanza personale (accesso ristretto)
├── genome-homelab/    ← submodule: infrastruttura Keru
└── AGENTS.md          ← questo file
```

## Regole di Coordinamento

- **core-karpathy/** è un submodule esterno in sola lettura. Non committare mai su di esso.
  Per aggiornarlo: `git submodule update --remote core-karpathy`
- Ogni genome-submodule ha il proprio `AGENTS.md` con le regole specifiche del dominio.
- Le ricerche cross-genome (es. pattern di codice che impattano la finanza) vanno documentate
  con wikilink inter-genome usando path relativi: `../genome-finance/wiki/concepts/...`
- Gli agenti operano **sempre** su un singolo genome alla volta, salvo query cross-genome
  esplicite.

## Aggiornamento dei Submodule

```bash
# Aggiorna core-karpathy all'ultimo commit del gist
git submodule update --remote core-karpathy

# Aggiorna tutti i genome all'ultimo commit del loro main
git submodule update --remote

# Dopo l'aggiornamento, registra i nuovi puntatori nel master
git add .
git commit -m "chore: update submodule pointers"
```

## Clonare il Repository con tutti i Submodule

```bash
git clone --recurse-submodules https://git.keruhomelab.com/keru/master-knowledge-genome.git
```

## Clonare un Solo Genome (Sparse)

```bash
# Solo genome-dev, senza scaricare finance o homelab
git clone https://git.keruhomelab.com/keru/genome-dev.git
```
EOF

# README minimo
cat > README.md << 'EOF'
# Master Knowledge Genome

Archivio radice del Knowledge Genome personale basato sul pattern [LLM Wiki di Karpathy](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f).

Leggi `AGENTS.md` per la documentazione operativa.
EOF

git add AGENTS.md README.md
git commit -m "chore: init master repo with global AGENTS.md"

# =============================================================================
step "5/6 — Aggiunta submodule core-karpathy e genome"
# =============================================================================

info "Aggiungendo core-karpathy dal gist di Karpathy..."
git submodule add "${GIST_URL}" core-karpathy
success "core-karpathy aggiunto."

info "Aggiungendo genome-submodule da Forgejo..."
for genome in "${GENOMES[@]}"; do
  git submodule add \
    "${FORGEJO_URL}/${FORGEJO_USER}/${genome}.git" \
    "${genome}"
  success "${genome} aggiunto come submodule."
done

git add .gitmodules
git add core-karpathy genome-dev genome-finance genome-homelab
git commit -m "feat: add core-karpathy gist and genome submodules"

# =============================================================================
step "6/6 — Push finale del master"
# =============================================================================

git push -u origin main
success "master-knowledge-genome pushato su Forgejo."

# =============================================================================
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Setup completato!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Repository creati su Forgejo:"
echo "  → ${FORGEJO_URL}/${FORGEJO_USER}/${MASTER_REPO}"
echo "  → ${FORGEJO_URL}/${FORGEJO_USER}/genome-dev"
echo "  → ${FORGEJO_URL}/${FORGEJO_USER}/genome-finance"
echo "  → ${FORGEJO_URL}/${FORGEJO_USER}/genome-homelab"
echo ""
echo "  Prossimi passi:"
echo "  1. Clona il master sul laptop con Obsidian:"
echo "     git clone --recurse-submodules \\"
echo "       ${FORGEJO_URL}/${FORGEJO_USER}/${MASTER_REPO}.git"
echo ""
echo "  2. Installa il plugin 'obsidian-git' e puntalo alla root del clone."
echo ""
echo "  3. Configura il webhook su Forgejo:"
echo "     genome-dev → Settings → Webhooks → Add Webhook"
echo "     Payload URL: http://10.0.10.20:5678/webhook/<uuid-n8n>"
echo "     Trigger: Push events"
echo ""
echo "  4. Aggiorna AGENTS.md di ciascun genome con il dominio specifico."
echo ""
