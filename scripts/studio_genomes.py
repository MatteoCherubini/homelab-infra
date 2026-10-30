#!/usr/bin/env python3
"""
studio_genomes.py — a genome is born from a row of Grist «Studio», table Genomi.

Runs on the laptop, never on the server. Grist is reached through `tailscale
serve`, which writes the device's identity on every request: there is no API
key, so there is none to store, and none that would also open «Finanze»
(docs/stacks/business.md). Standard library only.

    studio_genomes.py schema [--apply]   the Genomi table and Progetti.Genoma; dry unless --apply
    studio_genomes.py check              the timer's job: a notification for every row waiting
    studio_genomes.py create <code>      on the LAN: the genome for that row, then «creato» back

The genome is named after the row's code — `g0007` becomes `genome-g0007` —
and the row's label never leaves Grist: not into the repository, the registry,
a notification or a log. That is what keeps a client's name out of the machine.

Configuration, from the environment or ~/.config/studio/studio.env:
    GRIST_URL            https://<server>.<tailnet>.ts.net:<port>, as in the server's .env
    STUDIO_DOC_ID        the id of the «Studio» document
    KG_ORCHESTRATOR_DIR  the orchestrator checkout (default ~/Progetti/knowledge-genome-orchestrator)
    STUDIO_LAN_IP        an address reached only at home; `create` refuses when the
                         route to it goes through the tailnet
    STUDIO_NTFY_TOPIC    default genome-requests; `ntfy publish` reads host and token
                         from its own client.yml
    STUDIO_FORGEJO_ITEM  the Vaultwarden item holding the owner's forge token
                         (default "forgejo token")
"""

import datetime
import getpass
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

TABLE = "Genomi"
CODE_RE = re.compile(r"^g\d{4,}$")
REMIND_AFTER_S = 24 * 3600
DESCRIPTIONS = {"cliente": "Client genome", "storia": "Story genome", "interno": "Internal genome"}

# The table, as the API takes it. Codice and Stato are TRIGGER formulas: data
# columns computed once, when the row is created, and never again — a code that
# followed $id after a re-import would rename a genome that already exists.
# Rows are never deleted (Stato «chiuso» instead): Grist numbers a new row
# after the highest one, so deleting the last row could give its code away.
COLUMNS = [
    {"id": "Codice", "fields": {"label": "Codice", "type": "Text", "isFormula": False,
                                "formula": "'g%04d' % $id", "recalcWhen": 0}},
    {"id": "Etichetta", "fields": {"label": "Etichetta", "type": "Text"}},
    {"id": "Tipo", "fields": {"label": "Tipo", "type": "Choice",
                              "widgetOptions": json.dumps({"choices": list(DESCRIPTIONS)})}},
    {"id": "Consenso_Paperless", "fields": {"label": "Consenso Paperless", "type": "Int"}},
    {"id": "Avvia", "fields": {"label": "Avvia", "type": "Bool"}},
    {"id": "Stato", "fields": {"label": "Stato", "type": "Choice", "isFormula": False,
                               "formula": "'richiesto'", "recalcWhen": 0,
                               "widgetOptions": json.dumps(
                                   {"choices": ["richiesto", "creato", "in pausa", "chiuso"]})}},
    {"id": "Creato_il", "fields": {"label": "Creato il", "type": "Date"}},
    {"id": "Repo", "fields": {"label": "Repo", "type": "Text",
                              "widgetOptions": json.dumps({"widget": "HyperLink"})}},
    {"id": "Genoma", "fields": {"label": "Genoma", "type": "Text", "isFormula": True,
                                "formula": "'genome-' + $Codice if $Codice else ''"}},
    {"id": "Note", "fields": {"label": "Note", "type": "Text"}},
]
PROJECT_LINK = {"id": "Genoma", "fields": {"label": "Genoma", "type": f"Ref:{TABLE}"}}


class GristUnreachable(Exception):
    """Grist did not answer: off the tailnet, or the server is down."""


def load_config(env=None, path=None):
    """The environment wins over the file; the file fills what is missing."""
    env = dict(os.environ if env is None else env)
    path = path or os.path.expanduser("~/.config/studio/studio.env")
    if os.path.isfile(path):
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key.strip()):
                    env.setdefault(key.strip(), value.strip().strip('"'))
    env.setdefault("KG_ORCHESTRATOR_DIR", os.path.expanduser("~/Progetti/knowledge-genome-orchestrator"))
    env.setdefault("STUDIO_NTFY_TOPIC", "genome-requests")
    env.setdefault("STUDIO_FORGEJO_ITEM", "forgejo token")
    return env


class Grist:
    def __init__(self, url, doc, opener=urllib.request.urlopen):
        self.base = f"{url.rstrip('/')}/api/docs/{doc}"
        self.opener = opener

    def call(self, method, path, body=None):
        data = None if body is None else json.dumps(body).encode()
        # Content-Type is what makes Grist accept a write that carries only the
        # device's identity: a foreign page cannot send it without asking.
        req = urllib.request.Request(self.base + path, data=data, method=method,
                                     headers={"Content-Type": "application/json",
                                              "Accept": "application/json"})
        try:
            with self.opener(req, timeout=20) as resp:
                text = resp.read().decode()
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"{method} {path}: HTTP {e.code} {e.read().decode(errors='replace')[:200]}")
        except (urllib.error.URLError, OSError) as e:
            raise GristUnreachable(str(e))
        return json.loads(text) if text else {}

    def tables(self):
        return {t["id"] for t in self.call("GET", "/tables").get("tables", [])}

    def columns(self, table):
        return {c["id"] for c in self.call("GET", f"/tables/{table}/columns").get("columns", [])}

    def rows(self, table):
        return self.call("GET", f"/tables/{table}/records").get("records", [])

    def update(self, table, row_id, fields):
        self.call("PATCH", f"/tables/{table}/records", {"records": [{"id": row_id, "fields": fields}]})


# ── schema ──────────────────────────────────────────────────────────────────

def schema(grist, apply=False, say=print):
    """Create what is missing, never alter what exists. Returns the changes."""
    changes = []
    tables = grist.tables()
    if TABLE not in tables:
        changes.append(f"create table {TABLE} with {', '.join(c['id'] for c in COLUMNS)}")
        if apply:
            grist.call("POST", "/tables", {"tables": [{"id": TABLE, "columns": COLUMNS}]})
    else:
        have = grist.columns(TABLE)
        missing = [c for c in COLUMNS if c["id"] not in have]
        if missing:
            changes.append(f"add to {TABLE}: {', '.join(c['id'] for c in missing)}")
            if apply:
                grist.call("POST", f"/tables/{TABLE}/columns", {"columns": missing})
    if "Progetti" in tables and "Genoma" not in grist.columns("Progetti"):
        changes.append("add to Progetti: Genoma, a reference to Genomi")
        if apply:
            grist.call("POST", "/tables/Progetti/columns", {"columns": [PROJECT_LINK]})
    verb = "done" if apply else "would"
    for c in changes:
        say(f"  {verb}: {c}")
    if not changes:
        say("  the schema is already there")
    return changes


# ── check ───────────────────────────────────────────────────────────────────

def waiting(rows):
    """Rows asked for and not created yet."""
    return [r for r in rows
            if r["fields"].get("Avvia") and (r["fields"].get("Stato") or "richiesto") == "richiesto"
            and CODE_RE.match(r["fields"].get("Codice") or "")]


def notify(topic, title, message, run=subprocess.run):
    """ntfy's own client: host and token come from its client.yml."""
    return run(["ntfy", "publish", "--title", title, "--tags", "seedling", topic, message],
               capture_output=True, text=True).returncode == 0


def check(grist, cfg, state_path=None, now=None, run=subprocess.run, say=print):
    """One notification per waiting row, again after a day if still waiting."""
    state_path = state_path or os.path.expanduser("~/.local/state/studio-genomes/notified.json")
    now = now or time.time()
    try:
        rows = grist.rows(TABLE)
    except GristUnreachable:
        return 0   # away from the tailnet: nothing to say, and nothing wrong
    try:
        with open(state_path) as f:
            seen = json.load(f)
    except (OSError, ValueError):
        seen = {}
    sent = 0
    for r in waiting(rows):
        code = r["fields"]["Codice"]
        if code in seen and now - seen[code] < REMIND_AFTER_S:
            continue
        kind = r["fields"].get("Tipo") or "?"
        # The label stays in Grist: the notification travels through ntfy and
        # lands on a lock screen.
        if notify(cfg["STUDIO_NTFY_TOPIC"], f"genome-{code} to create",
                  f"Type: {kind}. From the laptop, on the LAN: studio_genomes.py create {code}", run=run):
            seen[code] = now
            sent += 1
    os.makedirs(os.path.dirname(state_path), exist_ok=True)
    with open(state_path, "w") as f:
        json.dump(seen, f)
    if sent:
        say(f"{sent} notification(s) sent")
    return sent


# ── create ──────────────────────────────────────────────────────────────────

def on_lan(ip, run=subprocess.run):
    """True when the route to a home-only address does not go through the tailnet."""
    if not ip:
        return False
    out = run(["ip", "route", "get", ip], capture_output=True, text=True)
    if out.returncode != 0:
        return False
    dev = re.search(r"\bdev (\S+)", out.stdout)
    return bool(dev) and not dev.group(1).startswith("tailscale")


def find_row(rows, code):
    return next((r for r in rows if r["fields"].get("Codice") == code), None)


def problems(row):
    """Why this row may not become a genome yet. Empty means it may."""
    if row is None:
        return ["no row with this code in Genomi"]
    f = row["fields"]
    out = []
    if not f.get("Avvia"):
        out.append("Avvia is not ticked")
    stato = f.get("Stato") or "richiesto"
    if stato != "richiesto":
        out.append(f"Stato is '{stato}', not 'richiesto'")
    if f.get("Tipo") not in DESCRIPTIONS:
        out.append("Tipo is not one of " + ", ".join(DESCRIPTIONS))
    elif f.get("Tipo") != "interno" and not f.get("Consenso_Paperless"):
        out.append("no Consenso Paperless: a person's genome starts with their signed consent")
    return out


def secrets(env, cfg, run=subprocess.run, ask=getpass.getpass):
    """BW_SESSION and FORGEJO_TOKEN for the run: Vaultwarden opened once."""
    env = dict(env)
    if not env.get("BW_SESSION"):
        out = run(["bw", "unlock", "--raw"], stdout=subprocess.PIPE, text=True)
        if out.returncode != 0 or not out.stdout.strip():
            raise RuntimeError("Vaultwarden did not unlock")
        env["BW_SESSION"] = out.stdout.strip()
    if not env.get("FORGEJO_TOKEN"):
        out = run(["bw", "get", "password", cfg["STUDIO_FORGEJO_ITEM"]], capture_output=True, text=True,
                  env=env)
        token = out.stdout.strip() if out.returncode == 0 else ""
        env["FORGEJO_TOKEN"] = token or ask("Forgejo token (yours, not the bot's): ")
    return env


def new_genome(cfg, genome, desc, apply, env, popen=subprocess.Popen, say=print):
    """The orchestrator's new-genome.sh, its lines shown as they come — a run
    waits for Syncthing for up to minutes, and silence reads as a hang. Its last
    line, KG_RESULT {...}, is the outcome."""
    cmd = ["bash", os.path.join(cfg["KG_ORCHESTRATOR_DIR"], "scripts", "new-genome.sh"),
           "--genome", genome, "--desc", desc] + (["--apply"] if apply else [])
    result = {}
    proc = popen(cmd, stdout=subprocess.PIPE, text=True, env=env)
    for line in proc.stdout:
        line = line.rstrip("\n")
        if line.startswith("KG_RESULT "):
            result = json.loads(line[len("KG_RESULT "):])
        else:
            say(line)
    proc.wait()
    return result


def create(grist, cfg, code, yes=False, run=subprocess.run, popen=subprocess.Popen, ask=input,
           env=None, say=print):
    if not CODE_RE.match(code):
        say(f"not a Genomi code: {code} (g0001, g0002, …)")
        return 1
    if not on_lan(cfg.get("STUDIO_LAN_IP", ""), run=run):
        say("not on the home LAN (STUDIO_LAN_IP is unset, or reached through the tailnet): "
            "a genome's key is born only at home")
        return 1
    row = find_row(grist.rows(TABLE), code)
    why = problems(row)
    if why:
        say(f"{code} cannot start yet:\n" + "\n".join(f"  - {w}" for w in why))
        return 1
    genome = f"genome-{code}"
    desc = DESCRIPTIONS[row["fields"]["Tipo"]]
    env = secrets(os.environ if env is None else env, cfg, run=run)

    preview = new_genome(cfg, genome, desc, False, env, popen=popen, say=say)
    if preview.get("status") != "dry":
        say("the dry run did not complete: read it above")
        return 1
    answer = "y" if yes else ask(f"Create {genome} ({row['fields']['Tipo']})? [y/N] ").strip().lower()
    if answer not in ("y", "yes", "s", "si", "sì"):
        say("nothing done")
        return 1

    result = new_genome(cfg, genome, desc, True, env, popen=popen, say=say)
    if result.get("status") != "created":
        say(f"{genome} is not finished: run the same command again once the lines above are fixed")
        return 1
    today = datetime.datetime.now(datetime.timezone.utc).date()
    midnight = int(datetime.datetime(today.year, today.month, today.day,
                                     tzinfo=datetime.timezone.utc).timestamp())
    grist.update(TABLE, row["id"], {"Stato": "creato", "Creato_il": midnight, "Repo": result.get("repo", "")})
    notify(cfg["STUDIO_NTFY_TOPIC"], f"{genome} created", "Ready: its folder is with the other Obsidian vaults.", run=run)
    say(f"{genome}: created, and Grist says so")
    return 0


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if not argv or argv[0] not in ("schema", "check", "create"):
        print(__doc__)
        return 2
    cfg = load_config()
    missing = [k for k in ("GRIST_URL", "STUDIO_DOC_ID") if not cfg.get(k)]
    if missing:
        print(f"missing {', '.join(missing)}: set them in ~/.config/studio/studio.env")
        return 2
    grist = Grist(cfg["GRIST_URL"], cfg["STUDIO_DOC_ID"])
    try:
        if argv[0] == "schema":
            schema(grist, apply="--apply" in argv[1:])
            return 0
        if argv[0] == "check":
            check(grist, cfg)
            return 0
        if len(argv) < 2:
            print("usage: studio_genomes.py create <code> [--yes]")
            return 2
        return create(grist, cfg, argv[1], yes="--yes" in argv[2:])
    except GristUnreachable as e:
        print(f"Grist does not answer at {cfg['GRIST_URL']}: {e}")
        return 1
    except RuntimeError as e:
        print(str(e))
        return 1


if __name__ == "__main__":
    sys.exit(main())
