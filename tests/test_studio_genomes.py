#!/usr/bin/env python3
"""
Tests for scripts/studio_genomes.py — standard library only, no network: Grist
is a recording fake, and every command the script would run (ntfy, ip, bw,
new-genome.sh) is a recording stand-in.

What each test pins is a way of going wrong that would not announce itself:
a client's label reaching a lock screen, a genome created off the LAN or
without consent, a row marked «creato» for a genome that is not finished.
"""

import importlib.util
import json
import os
import tempfile
import unittest

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location(
    "studio_genomes", os.path.join(BASE, "scripts", "studio_genomes.py"))
sg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sg)

CFG = {"STUDIO_NTFY_TOPIC": "genome-requests", "KG_ORCHESTRATOR_DIR": "/orch",
       "STUDIO_LAN_IP": "192.168.1.10", "STUDIO_FORGEJO_ITEM": "forgejo token"}
LABEL = "Sample Workshop of a Person"


class FakeGrist:
    def __init__(self, tables=None, rows=None, unreachable=False):
        self._tables = tables if tables is not None else {"Progetti": {"Nome"}, sg.TABLE: {c["id"] for c in sg.COLUMNS}}
        self._rows = rows or []
        self.unreachable = unreachable
        self.writes = []

    def tables(self):
        return set(self._tables)

    def columns(self, table):
        return set(self._tables[table])

    def rows(self, table):
        if self.unreachable:
            raise sg.GristUnreachable("no route")
        return self._rows

    def call(self, method, path, body=None):
        self.writes.append((method, path, body))
        return {}

    def update(self, table, row_id, fields):
        self.writes.append(("PATCH", table, {"id": row_id, "fields": fields}))


def row(rid=7, code="g0007", tipo="cliente", consent=12, avvia=True, stato="richiesto", label=LABEL):
    return {"id": rid, "fields": {"Codice": code, "Tipo": tipo, "Consenso_Paperless": consent,
                                  "Avvia": avvia, "Stato": stato, "Etichetta": label}}


class Done:
    def __init__(self, returncode=0, stdout=""):
        self.returncode, self.stdout = returncode, stdout


class Runner:
    """subprocess.run: records argv, answers by the command's first word."""

    def __init__(self, route="192.168.1.10 dev wlp0s20f3 src 192.168.1.20", notify_ok=True):
        self.calls, self.route, self.notify_ok = [], route, notify_ok

    def __call__(self, argv, **kw):
        self.calls.append(argv)
        if argv[0] == "ip":
            return Done(0, self.route)
        if argv[0] == "ntfy":
            return Done(0 if self.notify_ok else 1)
        if argv[:2] == ["bw", "unlock"]:
            return Done(0, "session\n")
        if argv[:2] == ["bw", "get"]:
            return Done(0, "forge-token\n")
        return Done(0)

    def ntfy(self):
        return [c for c in self.calls if c[0] == "ntfy"]


class Popen:
    """subprocess.Popen for new-genome.sh: the outcome line per mode."""

    def __init__(self, applied="created"):
        self.applied, self.calls = applied, []

    def __call__(self, argv, **kw):
        self.calls.append((argv, kw.get("env", {})))
        status = self.applied if "--apply" in argv else "dry"
        lines = ["  ✔ something\n", 'KG_RESULT {"genome":"genome-g0007","status":"%s",'
                 '"repo":"http://forge.example/owner/genome-g0007"}\n' % status]
        proc = type("P", (), {})()
        proc.stdout = iter(lines)
        proc.wait = lambda: 0
        return proc


def quiet(*_):
    pass


class SchemaTest(unittest.TestCase):
    def test_dry_run_writes_nothing_and_says_what_it_would_create(self):
        g = FakeGrist(tables={"Progetti": {"Nome"}})
        changes = sg.schema(g, apply=False, say=quiet)
        self.assertEqual(g.writes, [])
        self.assertTrue(any("create table Genomi" in c for c in changes))

    def test_apply_creates_the_table_and_links_projects_to_it(self):
        g = FakeGrist(tables={"Progetti": {"Nome"}})
        sg.schema(g, apply=True, say=quiet)
        posted = {path: body for _, path, body in g.writes}
        cols = posted["/tables"]["tables"][0]["columns"]
        self.assertEqual([c["id"] for c in cols], [c["id"] for c in sg.COLUMNS])
        self.assertEqual(posted["/tables/Progetti/columns"]["columns"][0]["fields"]["type"], "Ref:Genomi")

    def test_the_code_is_a_trigger_formula_computed_once(self):
        codice = next(c for c in sg.COLUMNS if c["id"] == "Codice")["fields"]
        self.assertFalse(codice["isFormula"], "a formula column would follow $id after a re-import")
        self.assertEqual(codice["recalcWhen"], 0)
        self.assertIn("%04d", codice["formula"])

    def test_an_existing_schema_is_left_alone(self):
        g = FakeGrist(tables={"Progetti": {"Nome", "Genoma"}, sg.TABLE: {c["id"] for c in sg.COLUMNS}})
        self.assertEqual(sg.schema(g, apply=True, say=quiet), [])
        self.assertEqual(g.writes, [])

    def test_only_the_missing_columns_are_added(self):
        g = FakeGrist(tables={"Progetti": {"Genoma"}, sg.TABLE: {"Codice", "Etichetta"}})
        sg.schema(g, apply=True, say=quiet)
        added = [c["id"] for c in g.writes[0][2]["columns"]]
        self.assertNotIn("Codice", added)
        self.assertIn("Avvia", added)


class CheckTest(unittest.TestCase):
    def setUp(self):
        self.state = os.path.join(tempfile.mkdtemp(), "notified.json")

    def test_a_waiting_row_is_notified_once_and_a_created_one_never(self):
        g = FakeGrist(rows=[row(), row(rid=8, code="g0008", stato="creato")])
        r = Runner()
        self.assertEqual(sg.check(g, CFG, self.state, now=1000, run=r, say=quiet), 1)
        self.assertEqual(sg.check(g, CFG, self.state, now=2000, run=r, say=quiet), 0)
        self.assertEqual(len(r.ntfy()), 1)
        self.assertIn("genome-g0007", " ".join(r.ntfy()[0]))

    def test_a_row_still_waiting_after_a_day_is_reminded(self):
        g, r = FakeGrist(rows=[row()]), Runner()
        sg.check(g, CFG, self.state, now=1000, run=r, say=quiet)
        sg.check(g, CFG, self.state, now=1000 + sg.REMIND_AFTER_S + 1, run=r, say=quiet)
        self.assertEqual(len(r.ntfy()), 2)

    def test_the_label_never_reaches_a_notification(self):
        g, r = FakeGrist(rows=[row()]), Runner()
        sg.check(g, CFG, self.state, now=1000, run=r, say=quiet)
        self.assertNotIn(LABEL, json.dumps(r.calls))

    def test_unticked_rows_wait_silently(self):
        g, r = FakeGrist(rows=[row(avvia=False)]), Runner()
        self.assertEqual(sg.check(g, CFG, self.state, now=1000, run=r, say=quiet), 0)

    def test_grist_out_of_reach_is_not_an_error(self):
        g, r = FakeGrist(unreachable=True), Runner()
        self.assertEqual(sg.check(g, CFG, self.state, now=1000, run=r, say=quiet), 0)
        self.assertEqual(r.calls, [])

    def test_a_notification_that_failed_is_tried_again_next_time(self):
        g = FakeGrist(rows=[row()])
        sg.check(g, CFG, self.state, now=1000, run=Runner(notify_ok=False), say=quiet)
        r = Runner()
        self.assertEqual(sg.check(g, CFG, self.state, now=1100, run=r, say=quiet), 1)


class CreateTest(unittest.TestCase):
    def go(self, rows, runner=None, popen=None, answer="y", code="g0007"):
        g = FakeGrist(rows=rows)
        runner = runner or Runner()
        popen = popen or Popen()
        rc = sg.create(g, CFG, code, run=runner, popen=popen, ask=lambda _: answer, env={}, say=quiet)
        return rc, g, runner, popen

    def test_the_genome_is_made_from_the_code_and_grist_is_told(self):
        rc, g, runner, popen = self.go([row()])
        self.assertEqual(rc, 0)
        (dry, _), (apply, env) = popen.calls
        self.assertNotIn("--apply", dry)
        self.assertIn("--apply", apply)
        self.assertEqual(apply[apply.index("--genome") + 1], "genome-g0007")
        self.assertEqual(apply[apply.index("--desc") + 1], "Client genome")
        self.assertEqual(env["FORGEJO_TOKEN"], "forge-token")
        self.assertEqual(env["BW_SESSION"], "session")
        fields = g.writes[-1][2]["fields"]
        self.assertEqual(fields["Stato"], "creato")
        self.assertTrue(fields["Repo"].endswith("/genome-g0007"))
        self.assertIsInstance(fields["Creato_il"], int)

    def test_the_label_goes_nowhere(self):
        _, _, runner, popen = self.go([row()])
        self.assertNotIn(LABEL, json.dumps([runner.calls, [c for c, _ in popen.calls]]))

    def test_off_the_lan_nothing_is_created(self):
        rc, g, _, popen = self.go([row()], runner=Runner(route="192.168.1.10 dev tailscale0 src 100.1.2.3"))
        self.assertEqual(rc, 1)
        self.assertEqual(popen.calls, [])
        self.assertEqual(g.writes, [])

    def test_a_person_without_consent_waits(self):
        rc, _, _, popen = self.go([row(consent=None)])
        self.assertEqual(rc, 1)
        self.assertEqual(popen.calls, [])

    def test_an_internal_genome_needs_no_consent(self):
        rc, _, _, _ = self.go([row(tipo="interno", consent=None)])
        self.assertEqual(rc, 0)

    def test_an_unticked_or_created_row_is_refused(self):
        for r in (row(avvia=False), row(stato="creato")):
            rc, _, _, popen = self.go([r])
            self.assertEqual(rc, 1)
            self.assertEqual(popen.calls, [])

    def test_an_unfinished_genome_is_not_marked_created(self):
        rc, g, _, _ = self.go([row()], popen=Popen(applied="incomplete"))
        self.assertEqual(rc, 1)
        self.assertEqual(g.writes, [])

    def test_saying_no_after_the_dry_run_changes_nothing(self):
        rc, g, _, popen = self.go([row()], answer="n")
        self.assertEqual(rc, 1)
        self.assertEqual(len(popen.calls), 1)
        self.assertEqual(g.writes, [])

    def test_vaultwarden_is_locked_again_by_the_run_that_unlocked_it(self):
        for answer, popen in (("y", Popen()), ("n", Popen()), ("y", Popen(applied="incomplete"))):
            _, _, runner, _ = self.go([row()], popen=popen, answer=answer)
            self.assertEqual(runner.calls[-1], ["bw", "lock"], f"not locked after answer {answer!r}")

    def test_a_session_that_was_already_open_is_left_to_its_owner(self):
        g, runner = FakeGrist(rows=[row()]), Runner()
        sg.create(g, CFG, "g0007", run=runner, popen=Popen(), ask=lambda _: "y",
                  env={"BW_SESSION": "theirs", "FORGEJO_TOKEN": "t"}, say=quiet)
        self.assertNotIn(["bw", "lock"], runner.calls)
        self.assertNotIn(["bw", "unlock", "--raw"], runner.calls)

    def test_a_code_that_is_not_a_genomi_code_is_refused(self):
        rc, _, runner, _ = self.go([row()], code="../etc")
        self.assertEqual(rc, 1)
        self.assertEqual(runner.calls, [])


class SmallPartsTest(unittest.TestCase):
    def test_the_lan_is_told_apart_from_the_tailnet(self):
        self.assertTrue(sg.on_lan("10.0.0.1", run=Runner(route="10.0.0.1 dev eth0 src 10.0.0.2")))
        self.assertFalse(sg.on_lan("10.0.0.1", run=Runner(route="10.0.0.1 dev tailscale0")))
        self.assertFalse(sg.on_lan("", run=Runner()))

    def test_the_environment_wins_over_the_file(self):
        path = os.path.join(tempfile.mkdtemp(), "studio.env")
        with open(path, "w") as f:
            f.write("GRIST_URL=https://file.example\nSTUDIO_DOC_ID=doc\n# comment\nbad line\n")
        cfg = sg.load_config(env={"GRIST_URL": "https://env.example"}, path=path)
        self.assertEqual(cfg["GRIST_URL"], "https://env.example")
        self.assertEqual(cfg["STUDIO_DOC_ID"], "doc")
        self.assertEqual(cfg["STUDIO_NTFY_TOPIC"], "genome-requests")


if __name__ == "__main__":
    unittest.main()
