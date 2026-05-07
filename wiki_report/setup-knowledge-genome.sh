#!/usr/bin/env bash
# =============================================================================
# setup-knowledge-genome.sh
# Bootstraps the full Knowledge Genome repository architecture on Forgejo.
#
# WHAT THIS SCRIPT DOES:
#   1. Creates 4 repositories on Forgejo via REST API:
#        master-knowledge-genome  (root, orchestrator)
#        genome-dev               (web dev, Angular, TUI, software architecture)
#        genome-finance           (personal finance, investments, market analysis)
#        genome-homelab           (Keru infrastructure, network, architecture logs)
#   2. Scaffolds each genome with:
#        - raw/{articles,transcripts,code-packs,assets}/  (plaintext, open to collaborators)
#        - raw/private/                                    (AES-256-CTR encrypted via git-crypt)
#        - wiki/{sources,entities,concepts,queries}/       (agent-maintained, plaintext)
#        - wiki/private/                                   (AES-256-CTR encrypted via git-crypt)
#        - .gitattributes                                  (declares encryption rules)
#        - .git/hooks/pre-commit                          (fail-safe: blocks plaintext leaks)
#        - AGENTS.md                                       (agent contract + PRIVATE_CONTEXT toggle)
#        - wiki/index.md, wiki/log.md
#   3. Exports a symmetric git-crypt key for each genome.
#   4. Builds the master repo with core-karpathy (Karpathy gist) and all genomes as submodules.
#
# PREREQUISITES:
#   - git          (any recent version)
#   - git-crypt    (apt install git-crypt  /  brew install git-crypt)
#   - curl
#   - jq           (apt install jq  /  brew install jq)
#   - Access to git.keruhomelab.com (LAN VLAN 10 or Cloudflare tunnel)
#   - A Forgejo API token with "repo" scope:
#     Forgejo → Settings → Applications → Access Tokens → Generate Token
#
# OPTIONAL (for runtime key injection — recommended for the AI server):
#   - bws  (Bitwarden Secrets Manager CLI)
#     https://bitwarden.com/help/secrets-manager-cli/
#
# USAGE:
#   chmod +x setup-knowledge-genome.sh
#   FORGEJO_TOKEN="your_token_here" ./setup-knowledge-genome.sh
#
# KEY MANAGEMENT (CRITICAL — read before running):
#   This script exports one symmetric key per genome to:
#     ~/knowledge-genome-setup/keys/<genome-name>.key
#   These keys are the ONLY way to decrypt raw/private/ and wiki/private/.
#   Losing them means permanent loss of access to encrypted content.
#
#   MANDATORY STEPS AFTER SETUP:
#     1. Upload each *.key file to Vaultwarden (vault.keruhomelab.com).
#        Store them as "Custom Fields" or secure notes under a "Knowledge Genome" item.
#     2. Delete the key files from disk:
#          rm ~/knowledge-genome-setup/keys/*.key
#     3. To unlock on any machine:
#          git-crypt unlock /path/to/<genome>.key
#     4. To unlock on the AI server WITHOUT persisting the key to disk
#        (recommended — requires bws CLI and a Vaultwarden Secrets Manager project):
#          git-crypt unlock <(bws secret get "BWS_SECRET_ID" | jq -r '.value')
#        This passes the key through a kernel file descriptor (process substitution),
#        meaning it is never written to any non-volatile storage.
#
# RUNTIME SECURITY MODEL:
#   - On Forgejo (remote): files in raw/private/ and wiki/private/ are opaque binary blobs.
#   - Collaborators who clone without the key see plaintext everywhere else,
#     and encrypted binary in private/ — git handles them gracefully (no errors).
#   - On your laptop and the AI VM: once unlocked, files are transparently decrypted
#     by the git smudge filter. Obsidian and the agent read them as normal Markdown.
#   - The encryption does NOT protect against a full server compromise where an
#     attacker has root access to a machine where the repo is already unlocked.
#     This is why runtime injection (step 4 above) is the strongest configuration.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURATION — edit only this section
# ---------------------------------------------------------------------------
FORGEJO_URL="https://git.keruhomelab.com"
FORGEJO_USER="keru"
FORGEJO_TOKEN="${FORGEJO_TOKEN:?Error: export FORGEJO_TOKEN before running this script.}"
GIST_URL="https://gist.github.com/442a6bf555914893e9891c11519de94f.git"
WORK_DIR="${HOME}/knowledge-genome-setup"
KEYS_DIR="${WORK_DIR}/keys"

MASTER_REPO="master-knowledge-genome"

# Each entry is: "<repo-name>|<description>"
# Visibility is handled at FILE level via git-crypt, not at repo level.
# All repos are created as private on Forgejo as a first layer of defence.
declare -A GENOME_DESCRIPTIONS=(
  ["genome-dev"]="Knowledge Genome: web development, TUI, Angular, software architecture"
  ["genome-finance"]="Knowledge Genome: personal finance, investments, market analysis"
  ["genome-homelab"]="Knowledge Genome: Keru infrastructure, network configs, architecture logs"
)
GENOMES=("genome-dev" "genome-finance" "genome-homelab")

# ---------------------------------------------------------------------------
# OUTPUT HELPERS
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}   $*"; }
success() { echo -e "${GREEN}[OK]${NC}     $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}   $*"; }
error()   { echo -e "${RED}[ERROR]${NC}  $*" >&2; }
step()    { echo -e "\n${BOLD}${YELLOW}━━━ $* ━━━${NC}"; }

# ---------------------------------------------------------------------------
# DEPENDENCY CHECK
# ---------------------------------------------------------------------------
check_deps() {
  local missing=()
  for cmd in git git-crypt curl jq; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required tools: ${missing[*]}"
    echo "  Ubuntu/Debian: sudo apt install ${missing[*]}"
    echo "  macOS:         brew install ${missing[*]}"
    exit 1
  fi
  if ! command -v bws &>/dev/null; then
    warn "'bws' (Bitwarden Secrets Manager CLI) is not installed."
    warn "Runtime key injection will require manual key file path."
    warn "Install: https://bitwarden.com/help/secrets-manager-cli/"
  fi
}

# ---------------------------------------------------------------------------
# FUNCTION: create a repository on Forgejo via REST API
# Usage: forgejo_create_repo <name> <description> <private: true|false>
# ---------------------------------------------------------------------------
forgejo_create_repo() {
  local name="$1" desc="$2" private="$3"
  local response http_code
  response=$(curl -s -w "\n%{http_code}" \
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
  http_code=$(echo "$response" | tail -1)

  case "$http_code" in
    201) success "Repository '${name}' created on Forgejo." ;;
    409) info    "Repository '${name}' already exists — skipping." ;;
    *)   error   "HTTP ${http_code} while creating '${name}'. Check token and Forgejo connectivity."; exit 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# FUNCTION: write the pre-commit hook that blocks accidental plaintext leaks
# Usage: write_precommit_hook <repo_path>
#
# How it works:
#   Before every commit, the hook inspects the list of staged files.
#   If any staged file lives under raw/private/ or wiki/private/, it runs
#   `git-crypt status` on that file. If git-crypt reports it as "not encrypted",
#   the commit is aborted with a clear error message.
#   This is the "fail-safe" described in the architecture document.
# ---------------------------------------------------------------------------
write_precommit_hook() {
  local repo_path="$1"
  local hook_path="${repo_path}/.git/hooks/pre-commit"

  cat > "${hook_path}" << 'HOOKEOF'
#!/usr/bin/env bash
# pre-commit hook: blocks plaintext commits to private/ directories.
# Installed by setup-knowledge-genome.sh — do not delete.

set -euo pipefail

PRIVATE_PATTERNS=("raw/private/" "wiki/private/")
FAILED=0

# Get list of staged files
STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)

if [[ -z "$STAGED_FILES" ]]; then
  exit 0
fi

for pattern in "${PRIVATE_PATTERNS[@]}"; do
  while IFS= read -r file; do
    if [[ "$file" == ${pattern}* ]]; then
      # Ask git-crypt if this specific file is encrypted
      STATUS=$(git-crypt status "$file" 2>/dev/null || echo "error")
      if echo "$STATUS" | grep -q "not encrypted"; then
        echo ""
        echo "  ┌─────────────────────────────────────────────────────┐"
        echo "  │  COMMIT BLOCKED — PLAINTEXT LEAK DETECTED           │"
        echo "  └─────────────────────────────────────────────────────┘"
        echo ""
        echo "  File:    $file"
        echo "  Reason:  This file is in a private/ directory but is NOT"
        echo "           being encrypted by git-crypt."
        echo ""
        echo "  Likely cause: .gitattributes rules are missing or incorrect."
        echo ""
        echo "  To fix:"
        echo "    1. Verify .gitattributes contains:"
        echo "         raw/private/** filter=git-crypt diff=git-crypt"
        echo "         wiki/private/** filter=git-crypt diff=git-crypt"
        echo "    2. Run: git-crypt status"
        echo "    3. If the repo is locked, unlock it first:"
        echo "         git-crypt unlock /path/to/<genome>.key"
        echo ""
        FAILED=1
      fi
    fi
  done <<< "$STAGED_FILES"
done

if [[ "$FAILED" -ne 0 ]]; then
  echo "  Commit aborted. Fix the issues above before retrying."
  echo ""
  exit 1
fi

exit 0
HOOKEOF

  chmod +x "${hook_path}"
  success "Pre-commit hook installed: ${repo_path}/.git/hooks/pre-commit"
}

# ---------------------------------------------------------------------------
# FUNCTION: scaffold a genome repository
# Creates all directories, template files, .gitattributes, hook, and AGENTS.md
# Usage: scaffold_genome <local_path>
# ---------------------------------------------------------------------------
scaffold_genome() {
  local base="$1"
  local name
  name=$(basename "$base")

  # ── Directory structure ──────────────────────────────────────────────────
  mkdir -p \
    "${base}/raw/articles" \
    "${base}/raw/transcripts" \
    "${base}/raw/code-packs" \
    "${base}/raw/assets" \
    "${base}/raw/private" \
    "${base}/wiki/sources" \
    "${base}/wiki/entities" \
    "${base}/wiki/concepts" \
    "${base}/wiki/queries" \
    "${base}/wiki/private"

  # .gitkeep ensures Git tracks empty directories
  for dir in \
    raw/articles raw/transcripts raw/code-packs raw/assets raw/private \
    wiki/sources wiki/entities wiki/concepts wiki/queries wiki/private; do
    touch "${base}/${dir}/.gitkeep"
  done

  # ── .gitattributes ────────────────────────────────────────────────────────
  # This file is the cryptographic contract of the repository.
  # The clean filter encrypts files before they enter the Git object store.
  # The smudge filter decrypts them when checked out locally.
  # WARNING: this file must never be modified carelessly.
  # Any file added to raw/private/ or wiki/private/ BEFORE git-crypt is
  # initialised would be stored in plaintext. The pre-commit hook prevents this.
  cat > "${base}/.gitattributes" << 'EOF'
# =============================================================================
# git-crypt encryption rules
# Files matching these patterns are encrypted with AES-256-CTR before being
# stored in the Git object store. They are transparently decrypted on checkout
# for authorised users who have run `git-crypt unlock`.
#
# Collaborators WITHOUT the key:
#   - Can read and contribute to everything outside private/
#   - See binary (illegible) blobs for files inside private/
#   - Git operations (add, commit, push, pull) work normally for them
#
# DO NOT modify or remove these rules without re-encrypting all private files.
# =============================================================================

raw/private/**   filter=git-crypt diff=git-crypt
wiki/private/**  filter=git-crypt diff=git-crypt
EOF

  # ── wiki/index.md ────────────────────────────────────────────────────────
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
