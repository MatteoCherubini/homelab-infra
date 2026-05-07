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

Master catalog of all pages in this genome. The agent updates this file on every ingest.
Search this file first before reading individual pages.

---

## Sources (wiki/sources/)
<!-- One entry per ingested source. Format: - [[sources/slug]] — one-line summary -->

## Entities (wiki/entities/)
<!-- People, tools, organisations, projects. -->

## Concepts (wiki/concepts/)
<!-- Patterns, theories, architectural decisions, methodologies. -->

## Archived Queries (wiki/queries/)
<!-- Synthesised answers worth preserving as standalone knowledge. -->

## Private Synthesis (wiki/private/)
<!-- Entries derived from personal data in raw/private/.
     Visible only when PRIVATE_CONTEXT: enabled and repo is unlocked.
     Listed here only by slug — no summaries to avoid leaking metadata. -->
EOF

  # ── wiki/log.md ──────────────────────────────────────────────────────────
  cat > "${base}/wiki/log.md" << EOF
---
title: "Operations Log — ${name}"
type: log
---

# Operations Log: ${name}

Append-only record of all agent operations. Never delete or edit past entries.

**Parse last 5 entries:**
\`\`\`bash
grep "^## \[" wiki/log.md | tail -5
\`\`\`

**Parse by operation type:**
\`\`\`bash
grep "^## \[" wiki/log.md | grep "ingest"
\`\`\`

---

## [$(date +%Y-%m-%d)] init | Repository scaffolded
Initial directory structure created by setup-knowledge-genome.sh.
No sources ingested yet. git-crypt active on raw/private/ and wiki/private/.
EOF

  # ── AGENTS.md ─────────────────────────────────────────────────────────────
  # This is the agent's operating contract. It must be read at the start of
  # every session. It defines rules, workflows, the PRIVATE_CONTEXT toggle,
  # and the collaboration model.
  cat > "${base}/AGENTS.md" << AGENTEOF
# Agent Schema: ${name}

**Read this file at the start of every session.**
It defines the rules, workflows, and conventions for the LLM agent that
maintains this genome. This file is the source of truth for agent behaviour.

---

## Genome Identity

| Field       | Value |
|-------------|-------|
| Name        | ${name} |
| Scope       | <!-- Describe the knowledge domain covered by this genome --> |
| Owner       | ${FORGEJO_USER} |
| Forgejo URL | ${FORGEJO_URL}/${FORGEJO_USER}/${name} |
| Created     | $(date +%Y-%m-%d) |

---

## Private Context Toggle

This toggle controls whether the agent may access encrypted personal data.
**It must be declared explicitly by the human operator in the session prompt.**
The agent must never assume or infer a value for this toggle.

\`\`\`
PRIVATE_CONTEXT: disabled
\`\`\`
or
\`\`\`
PRIVATE_CONTEXT: enabled
\`\`\`

**Default is always: disabled.**

### When PRIVATE_CONTEXT is disabled (default):
- The agent behaves as if raw/private/ and wiki/private/ do not exist.
- It must not read, reference, or acknowledge any file in those directories.
- All outputs are safe to share with collaborators.
- Use this mode for: collaborative sessions, professional reports, shared analysis,
  any session where a third party may see the output, cloud model usage.

### When PRIVATE_CONTEXT is enabled:
- The agent may read raw/private/ and wiki/private/.
- It may use personal data for: auto-filling document templates, personalised
  financial analysis, introspective queries, self-improvement tracking.
- Outputs from this mode are classified as personal and must not be shared.
- The agent must prefix every response that draws on private data with:
  \`[PRIVATE DATA INCLUDED]\`
- Commit messages for private content use the prefix: \`feat(wiki/private): ...\`

### On the AI server (runtime key injection):
The symmetric git-crypt key must never be stored as a persistent file on
the AI VM. Inject it at session start using Vaultwarden + bws CLI:
\`\`\`bash
# Unlock without writing the key to disk (process substitution)
git-crypt unlock <(bws secret get "BWS_SECRET_ID_FOR_${name^^}" | jq -r '.value')
\`\`\`
When the session ends, or if PRIVATE_CONTEXT transitions to disabled, run:
\`\`\`bash
git-crypt lock
\`\`\`

---

## Repository Structure

\`\`\`
${name}/
│
├── raw/                       ← IMMUTABLE: agent reads, never modifies
│   ├── articles/              │  Plaintext — open to collaborators
│   ├── transcripts/           │  Plaintext — open to collaborators
│   ├── code-packs/            │  Plaintext — open to collaborators
│   ├── assets/                │  Plaintext — open to collaborators
│   └── private/               │  AES-256-CTR encrypted (git-crypt)
│                              │  Owner-only: personal docs, logs, data
│
├── wiki/                      ← AGENT-OWNED: agent writes and maintains
│   ├── index.md               │  Master catalog — updated on every ingest
│   ├── log.md                 │  Append-only operations log
│   ├── sources/               │  One page per ingested source
│   ├── entities/              │  People, tools, organisations
│   ├── concepts/              │  Patterns, theories, decisions
│   ├── queries/               │  Archived synthesised answers
│   └── private/               │  AES-256-CTR encrypted (git-crypt)
│                              │  Personal syntheses, sensitive analysis
│
├── .gitattributes             ← Cryptographic rules (DO NOT MODIFY carelessly)
└── AGENTS.md                  ← This file
\`\`\`

---

## Core Rules

1. **raw/ is sacred and immutable.** Read files from raw/; never create, modify, or
   delete them. raw/ is the source of truth.

2. **wiki/ is owned by the agent.** Create, update, cross-link, and maintain all
   pages in wiki/ based on what has been ingested.

3. **Log every operation.** Every ingest, lint pass, or query that produces a
   saved output must be appended to wiki/log.md using the format:
   \`## [YYYY-MM-DD] <operation> | <title>\`

4. **Update the index on every ingest.** wiki/index.md must always reflect the
   current state of the wiki. Add the new page link immediately after creating it.

5. **Commits follow Conventional Commits:**
   - \`feat(wiki): add source page for <title>\`
   - \`fix(wiki): resolve contradiction in <concept>\`
   - \`chore(wiki): lint — orphan pages and stale claims\`
   - \`feat(wiki/private): add personal synthesis for <document>\`
   - \`docs(agents): update schema\`

6. **Never commit unencrypted personal data outside raw/private/ or wiki/private/.**
   The pre-commit hook enforces this automatically, but the agent must also
   respect this rule when proposing file locations.

7. **Contradict, don't overwrite.** If a new source contradicts an existing wiki
   claim, add a "Contradictions or Updates" section to the relevant concept page.
   The old claim stays as historical record with a deprecation note.

8. **No direct writes to main.** The agent always works on a feature branch and
   opens a Pull Request. The human operator reviews and merges.

---

## Ingest Workflow

Triggered by: a new file appearing in raw/ (via Forgejo webhook → n8n → agent).

1. Read the source document fully.
2. Discuss key takeaways with the operator, or generate an autonomous analysis.
3. Create \`wiki/sources/<slug>.md\` with: summary, key points, quotes worth preserving,
   and links to affected entity and concept pages.
4. For each person, tool, or organisation mentioned:
   → Update or create \`wiki/entities/<name>.md\`
5. For each pattern, theory, or architectural decision mentioned:
   → Update or create \`wiki/concepts/<name>.md\`
6. If a new claim contradicts an existing page → add "Contradictions or Updates" section.
7. Update \`wiki/index.md\` with the new source page link.
8. Append entry to \`wiki/log.md\`.
9. Stage all changes and create an atomic commit on branch \`feat/ai-ingest-<slug>\`.
10. Open a Pull Request on Forgejo for human review and approval.

**For private sources** (raw/private/, requires PRIVATE_CONTEXT: enabled):
- Steps are identical, but output files go to \`wiki/private/<slug>.md\`.
- PR description must begin with: \`[PRIVATE] Contains personal data.\`
- PR must not be merged during a collaborative or shared session.

---

## Query Workflow

When the operator asks a question:

1. Read \`wiki/index.md\` to identify relevant pages.
2. Read those pages (and wiki/private/ if PRIVATE_CONTEXT: enabled).
3. Synthesise a response using [[wikilink]] citations to source pages.
4. If PRIVATE_CONTEXT is enabled and private data informed the answer,
   prefix the response with \`[PRIVATE DATA INCLUDED]\`.
5. If the answer has lasting value → propose saving it to \`wiki/queries/<slug>.md\`.

For RAG implementations: during indexing, tag all chunks from private/ directories
with \`visibility: private\` metadata. Apply a metadata filter on retrieval to
exclude these chunks when PRIVATE_CONTEXT is disabled — even if they are indexed,
they remain invisible to the model without explicit authorisation.

---

## Lint Workflow (Periodic Maintenance)

1. Find orphan pages: wiki pages with no inbound [[wikilink]] from any other page.
2. Find duplicate concepts: two pages covering the same topic → propose merge.
3. Find implicit concepts: terms mentioned across 3+ pages without a dedicated page.
4. Find stale claims: assertions that newer sources may have superseded.
5. Verify YAML frontmatter is correct and complete on all pages (see format below).
6. Report findings as a structured list → do not auto-fix without operator approval.
7. Log the lint pass in wiki/log.md regardless of findings.

---

## YAML Frontmatter Format

All wiki pages must begin with valid YAML frontmatter:

\`\`\`yaml
---
title: "Human-readable page title"
type: source | entity | concept | query | private
domain: ${name}
tags: []
confidence: high | medium | low
last_updated: YYYY-MM-DD
source_count: N        # number of sources that support this page (concept/entity only)
private: false         # set to true for all pages inside wiki/private/
---
\`\`\`

---

## Collaboration Model

| Role | Access | Permitted Operations |
|------|--------|----------------------|
| Owner (you) | Full — key holder | Read/write everywhere, can unlock private/ |
| Trusted collaborator | Partial — no key | Push to raw/articles, raw/transcripts, raw/code-packs, raw/assets |
| AI agent (local LLM) | Conditional | Reads private/ only when PRIVATE_CONTEXT: enabled and repo is unlocked |
| AI agent (cloud LLM) | Public only | PRIVATE_CONTEXT must be disabled; never send private files to cloud models |

To grant a collaborator write access to public folders only:
- Add them as a Forgejo collaborator with "Write" role.
- Do NOT share the git-crypt key.
- They will see encrypted blobs in private/ — this is correct and expected.

To add a trusted person to the private layer (exceptional cases only):
\`\`\`bash
git-crypt add-gpg-user <their-GPG-key-fingerprint>
\`\`\`
Note: revoking access from a GPG user requires re-generating the symmetric key
and re-encrypting all private files. Prefer not to share the private layer.
AGENTEOF

  # ── .gitignore ───────────────────────────────────────────────────────────
  cat > "${base}/.gitignore" << 'EOF'
# OS artifacts
.DS_Store
Thumbs.db
desktop.ini

# Obsidian runtime files
# Config (.obsidian/) is tracked so vault settings are preserved across machines.
# Runtime and cache files are excluded.
.obsidian/workspace.json
.obsidian/workspace-mobile.json
.obsidian/cache
.obsidian/.plugin-stats

# Temporary files
*.tmp
*.bak
*~

# git-crypt symmetric keys — NEVER commit these
*.key

# Python / Node artifacts that might appear in code-packs
__pycache__/
node_modules/
.env
EOF

  success "Scaffold complete for: ${name}"
}

# =============================================================================
# MAIN
# =============================================================================

step "0/7 — Dependency check"
check_deps

step "1/7 — Preparing local workspace"
mkdir -p "${WORK_DIR}" "${KEYS_DIR}"
cd "${WORK_DIR}"
info "Working directory : ${WORK_DIR}"
info "Keys directory    : ${KEYS_DIR}"
warn "Remember: move all *.key files to Vaultwarden and delete from disk after setup."

# =============================================================================
step "2/7 — Creating repositories on Forgejo"
# =============================================================================

forgejo_create_repo \
  "${MASTER_REPO}" \
  "Master Knowledge Genome — root repository with domain genome submodules" \
  "true"

for genome in "${GENOMES[@]}"; do
  forgejo_create_repo \
    "${genome}" \
    "${GENOME_DESCRIPTIONS[$genome]}" \
    "true"
done

# =============================================================================
step "3/7 — Scaffolding, encrypting, and pushing genome repositories"
# =============================================================================

for genome in "${GENOMES[@]}"; do
  info "──────────────────────────────────────────"
  info "Processing: ${genome}"

  local_path="${WORK_DIR}/${genome}"
  mkdir -p "${local_path}"
  cd "${local_path}"

  # Initialise git and set remote
  git init -b main
  git remote add origin "${FORGEJO_URL}/${FORGEJO_USER}/${genome}.git"

  # Configure git identity for commits (uses global config if already set)
  git config user.name  "${FORGEJO_USER}" 2>/dev/null || true
  git config user.email "${FORGEJO_USER}@keruhomelab.com" 2>/dev/null || true

  # Initialise git-crypt BEFORE creating any files in private/ directories.
  # This ensures .gitattributes rules are active from the very first commit.
  git-crypt init
  info "git-crypt initialised for ${genome}."

  # Scaffold all directories and template files
  scaffold_genome "${local_path}"

  # Install the pre-commit hook (fail-safe against plaintext leaks)
  write_precommit_hook "${local_path}"

  # Stage and commit everything
  git add .
  git commit -m "chore: initial scaffold — git-crypt active on private/"

  # Export the symmetric key before pushing.
  # The key is a binary file — store it in Vaultwarden as a secure note
  # or encode it to base64 for the bws Secrets Manager:
  #   base64 < keys/<genome>.key | bws secret create "GENOME_KEY_<NAME>" -
  git-crypt export-key "${KEYS_DIR}/${genome}.key"
  success "Symmetric key exported: ${KEYS_DIR}/${genome}.key"

  # Push to Forgejo
  git push -u origin main
  success "${genome} pushed to Forgejo."

  # Verify encryption is working correctly by locking and checking
  info "Verifying encryption on ${genome}/raw/private/.gitkeep..."
  git-crypt lock
  if file "${local_path}/raw/private/.gitkeep" | grep -q "data"; then
    success "Encryption verified: raw/private/ is locked (binary blob)."
  else
    warn "Encryption check inconclusive — verify manually with: git-crypt status"
  fi
  # Unlock again so the working tree is clean for subsequent steps
  git-crypt unlock "${KEYS_DIR}/${genome}.key"

  cd "${WORK_DIR}"
done

# =============================================================================
step "4/7 — Initialising master-knowledge-genome"
# =============================================================================

mkdir -p "${WORK_DIR}/${MASTER_REPO}"
cd "${WORK_DIR}/${MASTER_REPO}"
git init -b main
git remote add origin "${FORGEJO_URL}/${FORGEJO_USER}/${MASTER_REPO}.git"
git config user.name  "${FORGEJO_USER}" 2>/dev/null || true
git config user.email "${FORGEJO_USER}@keruhomelab.com" 2>/dev/null || true

# ── Global AGENTS.md ─────────────────────────────────────────────────────────
cat > AGENTS.md << EOF
# Global Schema: master-knowledge-genome

This file coordinates all genome submodules of the personal Knowledge Genome.
Read it before starting any cross-genome session.

---

## Repository Structure

\`\`\`
master-knowledge-genome/
├── core-karpathy/      ← submodule: Karpathy LLM Wiki pattern (read-only reference)
├── genome-dev/         ← submodule: development, Angular, TUI, software architecture
├── genome-finance/     ← submodule: personal finance, investments, market analysis
├── genome-homelab/     ← submodule: Keru infrastructure, network, architecture logs
└── AGENTS.md           ← this file
\`\`\`

Each genome submodule has its own \`AGENTS.md\` with domain-specific rules.

---

## Cross-Genome Rules

- **core-karpathy/** is a read-only external reference. Never commit to it.
  To update it to the latest gist commit:
  \`\`\`bash
  git submodule update --remote core-karpathy
  \`\`\`

- Agents operate on **one genome at a time** unless a cross-genome query is
  explicitly requested by the operator.

- Cross-genome wikilinks use relative paths:
  \`\`\`
  [[../genome-finance/wiki/concepts/risk-management]]
  \`\`\`

- The PRIVATE_CONTEXT toggle is **per-genome and per-session**.
  Enabling it for genome-finance does not enable it for genome-dev.
  Enabling it implies the relevant genome is also unlocked via git-crypt.

- Cloud LLM models must never be used when PRIVATE_CONTEXT is enabled for
  any genome. Private data must not leave the local network.

---

## Submodule Operations

\`\`\`bash
# Update core-karpathy to the latest gist commit
git submodule update --remote core-karpathy

# Update all genomes to their latest main commit
git submodule update --remote

# Record the updated submodule pointers in the master repo
git add .
git commit -m "chore: update submodule pointers"
git push
\`\`\`

---

## Cloning

\`\`\`bash
# Full clone with all submodules (your laptop, fresh setup)
git clone --recurse-submodules \\
  ${FORGEJO_URL}/${FORGEJO_USER}/${MASTER_REPO}.git

# After cloning, unlock each genome you need access to:
cd master-knowledge-genome/genome-dev
git-crypt unlock /path/to/genome-dev.key

# Or with runtime injection from Vaultwarden (AI server — no key on disk):
git-crypt unlock <(bws secret get "BWS_SECRET_ID_GENOME_DEV" | jq -r '.value')

# Clone a single genome (for a collaborator who only needs genome-dev):
git clone ${FORGEJO_URL}/${FORGEJO_USER}/genome-dev.git
# They will see encrypted blobs in private/ — correct and expected behaviour.
\`\`\`

---

## Key Management Reference

| Genome | Key File | Vaultwarden Entry (suggested) |
|--------|----------|-------------------------------|
| genome-dev | genome-dev.key | Knowledge Genome / genome-dev key |
| genome-finance | genome-finance.key | Knowledge Genome / genome-finance key |
| genome-homelab | genome-homelab.key | Knowledge Genome / genome-homelab key |

Symmetric keys are binary files. To store in Vaultwarden Secrets Manager:
\`\`\`bash
base64 < genome-dev.key | bws secret create "GENOME_KEY_DEV"
\`\`\`
To retrieve and decode for manual unlock:
\`\`\`bash
bws secret get "BWS_SECRET_ID" | jq -r '.value' | base64 -d > /tmp/genome-dev.key
git-crypt unlock /tmp/genome-dev.key
rm /tmp/genome-dev.key
\`\`\`
EOF

# ── README ───────────────────────────────────────────────────────────────────
cat > README.md << 'EOF'
# master-knowledge-genome

Root repository for the personal Knowledge Genome.
Based on [Karpathy's LLM Wiki pattern](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f).

See `AGENTS.md` for the full operational schema.
EOF

git add AGENTS.md README.md
git commit -m "chore: init master repo with global AGENTS.md"

# =============================================================================
step "5/7 — Adding core-karpathy submodule (Karpathy gist)"
# =============================================================================

info "Adding core-karpathy from Karpathy's gist..."
git submodule add "${GIST_URL}" core-karpathy
success "core-karpathy submodule added."

# =============================================================================
step "6/7 — Adding genome submodules"
# =============================================================================

for genome in "${GENOMES[@]}"; do
  git submodule add \
    "${FORGEJO_URL}/${FORGEJO_USER}/${genome}.git" \
    "${genome}"
  success "${genome} added as submodule."
done

git add .gitmodules core-karpathy "${GENOMES[@]}"
git commit -m "feat: add core-karpathy gist and genome submodules"

# =============================================================================
step "7/7 — Pushing master repository"
# =============================================================================

git push -u origin main
success "master-knowledge-genome pushed to Forgejo."

# =============================================================================
# FINAL SUMMARY
# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${GREEN}  Setup complete.${NC}"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Repositories on Forgejo:"
echo -e "  → ${CYAN}${FORGEJO_URL}/${FORGEJO_USER}/${MASTER_REPO}${NC}"
for genome in "${GENOMES[@]}"; do
  echo -e "  → ${CYAN}${FORGEJO_URL}/${FORGEJO_USER}/${genome}${NC}"
done
echo ""
echo -e "  ${RED}${BOLD}CRITICAL — git-crypt keys (act now):${NC}"
for genome in "${GENOMES[@]}"; do
  echo "    ${KEYS_DIR}/${genome}.key"
done
echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │  1. Upload each .key to Vaultwarden (vault.keruhomelab.com) │"
echo "  │     Use: base64 < <genome>.key | bws secret create \"name\"   │"
echo "  │  2. Delete keys from disk: rm ${KEYS_DIR}/*.key  │"
echo "  │  3. Test encryption: cd genome-dev && git-crypt lock         │"
echo "  │     Try to cat raw/private/.gitkeep — you should see binary  │"
echo "  │     Then unlock: git-crypt unlock /path/to/genome-dev.key    │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
echo "  Next steps:"
echo ""
echo "  1. Clone on your laptop with Obsidian:"
echo "       git clone --recurse-submodules \\"
echo "         ${FORGEJO_URL}/${FORGEJO_USER}/${MASTER_REPO}.git"
echo "       cd ${MASTER_REPO}/genome-dev"
echo "       git-crypt unlock /path/to/genome-dev.key"
echo ""
echo "  2. Open the clone root in Obsidian. Install 'obsidian-git' plugin."
echo "     Point it to the genome subfolder you work in most."
echo ""
echo "  3. Fill in the 'Scope' field in each genome's AGENTS.md."
echo ""
echo "  4. Set up Forgejo webhooks to trigger n8n on push:"
echo "       Per genome: Settings → Webhooks → Add Webhook"
echo "       Payload URL: http://10.0.10.20:5678/webhook/<n8n-uuid>"
echo "       Content type: application/json — Trigger: Push events"
echo ""
echo "  5. On the AI VM (when ready):"
echo "       git clone --recurse-submodules \\"
echo "         ${FORGEJO_URL}/${FORGEJO_USER}/${MASTER_REPO}.git"
echo "       cd ${MASTER_REPO}/genome-dev"
echo "       git-crypt unlock <(bws secret get \"BWS_ID\" | jq -r '.value')"
echo ""
