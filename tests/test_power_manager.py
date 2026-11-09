#!/usr/bin/env python3
"""
Tests for workflows/power-manager.json — standard library only, no n8n, no
network. The flow is read as a graph, and the one command that decides
whether anything may be switched on runs for real under /bin/sh, against a
fake `upsc`.

What they pin is the blackout: with the server on battery, the hypervisor has
been shut down on purpose (docs/stacks/ups.md), and the next ingest or the
fifteen-minute safety-net asks this flow to bring it back. Woken on battery,
it draws ~400 W, the shutdown timer that stopped it fires once per outage, and
at low battery it loses power hard. Nothing announces that until it happens.

They also pin the standby: `ensure-off` answers `hypervisor: standby` only once
the hypervisor has stopped answering and stayed down. On 2026-11-08 a USB wake
left an ACPI event firing on the hypervisor, it woke from every suspend, and
for half an hour the flow reported "standby" every five minutes: the answer
read only whether the arbiter had said `skip:`.
"""

import json
import os
import re
import subprocess
import tempfile
import unittest

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
with open(os.path.join(BASE, "workflows", "power-manager.json"), encoding="utf-8") as f:
    FLOW = json.load(f)
NODES = {n["name"]: n for n in FLOW["nodes"]}


def command(node):
    return node.get("parameters", {}).get("command", "")


def ssh_nodes(text):
    return [n["name"] for n in FLOW["nodes"]
            if n["type"] == "n8n-nodes-base.ssh" and text in command(n)]


def outputs(name):
    """The nodes behind each output of a node, by output index."""
    return [[c["node"] for c in out] for out in FLOW["connections"].get(name, {}).get("main", [])]


def reachable(starts, avoid=()):
    seen, stack = set(), list(starts)
    while stack:
        name = stack.pop()
        if name in seen or name in avoid:
            continue
        seen.add(name)
        for out in outputs(name):
            stack.extend(out)
    return seen


def trigger():
    return next(n["name"] for n in FLOW["nodes"]
                if n["type"] == "n8n-nodes-base.executeWorkflowTrigger")


def switch_output(mode):
    """The Switch output that a caller's `mode` takes."""
    sw = next(n for n in FLOW["nodes"] if n["type"] == "n8n-nodes-base.switch")
    for i, rule in enumerate(sw["parameters"]["rules"]["values"]):
        if any(c["rightValue"] == mode for c in rule["conditions"]["conditions"]):
            return outputs(sw["name"])[i]
    raise AssertionError(f"the Switch has no output for mode {mode!r}")


# The nodes that switch something on. Found by what they run, not by name, so
# a renamed node is still found and a second one added later is too.
WAKES = ssh_nodes("wakeonlan") + ssh_nodes("ai-node start")


def ups_probe():
    found = ssh_nodes("upsc")
    if len(found) != 1:
        raise AssertionError(f"expected one node that reads the UPS, found {found}")
    return found[0]


def gate():
    nxt = [n for out in outputs(ups_probe()) for n in out]
    if len(nxt) != 1 or NODES[nxt[0]]["type"] != "n8n-nodes-base.if":
        raise AssertionError(f"the UPS reading should go to one If node, it goes to {nxt}")
    return nxt[0]


def branch(name, stdout):
    """Which output an n8n If node (v2) takes for an SSH node's stdout:
    0 when the conditions hold, 1 when they do not."""
    conds = NODES[name]["parameters"]["conditions"]
    results = []
    for c in conds["conditions"]:
        left = c["leftValue"]
        if left == "={{ $json.stdout }}":
            value = stdout
        elif left == "={{ ($json.stdout || '').trim() }}":
            value = stdout.strip()
        else:
            raise AssertionError(f"{name}: a condition on {left!r}, which this test cannot evaluate")
        op, right = c["operator"], c["rightValue"]
        if op["type"] != "string":
            raise AssertionError(f"{name}: a {op['type']} condition, which this test cannot evaluate")
        results.append({"equals": value == right, "contains": right in value,
                        "startsWith": value.startswith(right)}[op["operation"]])
    held = all(results) if conds["combinator"] == "and" else any(results)
    return 0 if held else 1


# The real upsc prints the SSL line on stderr on some builds, and answers an
# unreadable UPS with an error and a non-zero exit: the answer must depend on
# neither.
FAKE_UPSC = r'''#!/bin/sh
echo "Init SSL without certificate database" >&2
if [ "$1" = -l ]; then printf '%s' "$FAKE_LIST"; exit 0; fi
eval "st=\${FAKE_$1-}"
if [ -z "$st" ]; then echo "Error: Driver not connected" >&2; exit 1; fi
printf '%s\n' "$st"
'''


def read_ups(upses, with_upsc=True):
    """Run the probe's command as n8n-runner's shell would, with `upses` as
    {name: ups.status}. Only `paste` and the fake `upsc` are on the PATH, so a
    real NUT on the machine running the tests cannot answer in its place."""
    bindir = tempfile.mkdtemp()
    os.symlink("/usr/bin/paste", os.path.join(bindir, "paste"))
    if with_upsc:
        fake = os.path.join(bindir, "upsc")
        with open(fake, "w") as f:
            f.write(FAKE_UPSC)
        os.chmod(fake, 0o755)
    env = {"PATH": bindir, "FAKE_LIST": "".join(f"{u}\n" for u in upses)}
    env.update({f"FAKE_{u}": st for u, st in upses.items()})
    run = subprocess.run(["/bin/sh", "-c", command(NODES[ups_probe()])],
                         capture_output=True, text=True, env=env, timeout=10)
    return run.stdout


class BatteryGateTest(unittest.TestCase):

    def test_nothing_is_switched_on_without_passing_the_gate(self):
        self.assertTrue(ssh_nodes("wakeonlan"), "no Wake-on-LAN node found: has the flow changed?")
        self.assertTrue(ssh_nodes("ai-node start"), "no AI node start found: has the flow changed?")
        around = reachable([trigger()], avoid={gate()})
        for wake in WAKES:
            self.assertNotIn(wake, around, f"'{wake}' can be reached without the battery gate")

    def test_ensure_on_meets_the_gate_before_anything_else_runs(self):
        # Before the probe of the hypervisor too: in the grace period the
        # hypervisor is still up, and starting the AI node on it then means a
        # guest killed by the emergency shutdown a moment later.
        self.assertEqual(switch_output("ensure-on"), [ups_probe()])

    def test_switching_off_never_waits_for_the_ups(self):
        # On battery, stopping is the one thing that should always go through.
        for mode in ("ensure-off", "status"):
            self.assertNotIn(ups_probe(), reachable(switch_output(mode)),
                             f"mode {mode} passes through the battery gate")

    def test_on_battery_nothing_is_switched_on_and_the_answer_is_blocked(self):
        for status in ("OB DISCHRG", "OB LB", "FSD OB LB", "OB"):
            with self.subTest(status=status):
                out = read_ups({"ups": status})
                after = reachable(outputs(gate())[branch(gate(), out)])
                for wake in WAKES:
                    self.assertNotIn(wake, after, f"{status!r} still reaches '{wake}'")
                ends = [NODES[n] for n in after if NODES[n]["type"] == "n8n-nodes-base.set"]
                self.assertEqual(len(ends), 1, f"{status!r} should end in one answer, got {[n['name'] for n in ends]}")
                fields = {a["name"]: a["value"] for a in ends[0]["parameters"]["assignments"]["assignments"]}
                self.assertEqual(fields.get("status"), "blocked")
                self.assertEqual(fields.get("mode"), "ensure-on")
                # The callers put blocked_by in the notification: what the UPS
                # said has to reach it.
                self.assertIn("$json.stdout", fields.get("blocked_by", ""))

    def test_on_mains_the_flow_goes_on_as_before(self):
        for status in ("OL", "OL CHRG", "OL BOOST"):
            with self.subTest(status=status):
                out = read_ups({"ups": status})
                after = reachable(outputs(gate())[branch(gate(), out)])
                self.assertIn(ssh_nodes("wakeonlan")[0], after, f"{status!r} can no longer wake the hypervisor")

    def test_a_ups_that_cannot_be_read_does_not_stop_the_work(self):
        # A lost link to the UPS already has its own notice (COMMBAD, NOCOMM),
        # and with no reading there is no ONBATT and no shutdown either: refusing
        # here would stop every ingest for a monitoring fault, and protect nothing.
        for label, out in (("no NUT installed", read_ups({}, with_upsc=False)),
                           ("upsc lists nothing", read_ups({})),
                           ("the driver is not connected", read_ups({"ups": ""}))):
            with self.subTest(label):
                after = reachable(outputs(gate())[branch(gate(), out)])
                self.assertIn(ssh_nodes("wakeonlan")[0], after, f"{label}: the flow stopped ({out!r})")

    def test_any_ups_on_battery_is_enough(self):
        out = read_ups({"ups": "OL", "second": "OB DISCHRG"})
        after = reachable(outputs(gate())[branch(gate(), out)])
        self.assertNotIn(ssh_nodes("wakeonlan")[0], after, f"one UPS on battery was missed ({out!r})")


def fields(name):
    return {a["name"]: a["value"] for a in NODES[name]["parameters"]["assignments"]["assignments"]}


def answers(names):
    return [n for n in names if NODES[n]["type"] == "n8n-nodes-base.set"]


def standby_request():
    found = ssh_nodes("standby-if-idle")
    if len(found) != 1:
        raise AssertionError(f"expected one node that asks for the standby, found {found}")
    return found[0]


def standby_answer():
    found = [n for n in answers(NODES) if fields(n).get("hypervisor") == "standby"]
    if len(found) != 1:
        raise AssertionError(f"expected one answer that says the hypervisor is on standby, found {found}")
    return found[0]


def standby_check():
    """The SSH node, after the standby request, that asks the hypervisor again."""
    found = [n for n in reachable([standby_request()]) if n != standby_request()
             and NODES[n]["type"] == "n8n-nodes-base.ssh" and KG_HOST in command(NODES[n])]
    if len(found) != 1:
        raise AssertionError(f"expected one check of the hypervisor after the standby request, found {found}")
    return found[0]


def standby_verdict():
    nxt = [n for out in outputs(standby_check()) for n in out]
    if len(nxt) != 1 or NODES[nxt[0]]["type"] != "n8n-nodes-base.if":
        raise AssertionError(f"the standby check should go to one If node, it goes to {nxt}")
    return nxt[0]


KG_HOST = "{{ $env.KG_HYPERVISOR_HOST }}"

# Stands in for ssh: exit 255 (what ssh returns when it cannot connect) for the
# first $FAKE_DOWN calls, then an answer. Every call and every sleep is logged,
# so the test sees how it was asked and how long the check would wait.
FAKE_SSH = r'''#!/bin/sh
echo "$*" >> "$FAKE_LOG"
n=$(cat "$FAKE_COUNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_COUNT"
if [ "$n" -le "$FAKE_DOWN" ]; then echo "ssh: connect to host hypervisor port 22: Connection timed out" >&2; exit 255; fi
echo stopped
exit "${FAKE_RC:-0}"
'''
FAKE_SLEEP = r'''#!/bin/sh
echo "$1" >> "$FAKE_SLEEPS"
'''


def check_standby(down, rc=0):
    """Run the standby check as n8n-runner's shell would, with the hypervisor
    unreachable for the first `down` connections. Returns (stdout, ssh calls,
    seconds slept)."""
    work = tempfile.mkdtemp()
    bindir = os.path.join(work, "bin")
    os.mkdir(bindir)
    os.symlink("/bin/cat", os.path.join(bindir, "cat"))
    for name, text in (("ssh", FAKE_SSH), ("sleep", FAKE_SLEEP)):
        path = os.path.join(bindir, name)
        with open(path, "w") as f:
            f.write(text)
        os.chmod(path, 0o755)
    env = {"PATH": bindir, "FAKE_DOWN": str(down), "FAKE_RC": str(rc), "FAKE_LOG": os.path.join(work, "ssh"),
           "FAKE_COUNT": os.path.join(work, "count"), "FAKE_SLEEPS": os.path.join(work, "sleeps")}
    cmd = command(NODES[standby_check()]).lstrip("=")
    cmd = re.sub(r"\{\{\s*\$env\.(\w+)\s*\}\}", lambda m: {"KG_HYPERVISOR_HOST": "hypervisor",
                                                           "KG_AI_VMID": "101"}[m.group(1)], cmd)
    run = subprocess.run(["/bin/sh", "-c", cmd], capture_output=True, text=True, env=env, timeout=10)

    def lines(name):
        path = os.path.join(work, name)
        return open(path).read().splitlines() if os.path.exists(path) else []
    return run.stdout, lines("ssh"), sum(int(s) for s in lines("sleeps"))


def after_check(down, rc=0):
    out, _, _ = check_standby(down, rc)
    return reachable(outputs(standby_verdict())[branch(standby_verdict(), out)])


class StandbyTest(unittest.TestCase):

    def test_standby_is_reported_only_after_the_check(self):
        around = reachable([standby_request()], avoid={standby_check()})
        self.assertNotIn(standby_answer(), around,
                         "the flow can say 'standby' without checking that the hypervisor went down")

    def test_a_hypervisor_that_stays_down_is_on_standby(self):
        after = after_check(down=1000)
        self.assertIn(standby_answer(), after)
        self.assertEqual(answers(after), [standby_answer()])

    def test_a_hypervisor_that_still_answers_is_blocked(self):
        # The suspend failed, or the request never reached the arbiter.
        self.assertNotIn(standby_answer(), after_check(down=0))

    def test_a_hypervisor_that_wakes_again_is_blocked(self):
        # 2026-11-08: suspended, woken a few seconds later by a stuck ACPI event.
        self.assertNotIn(standby_answer(), after_check(down=2))

    def test_an_answer_with_an_error_is_still_an_answer(self):
        # `unauthorized command`, or a guest id the arbiter does not know: the
        # command failed, but the hypervisor answered, so it is awake. Only
        # ssh's own 255 means that nothing answered.
        for rc in (1, 2):
            with self.subTest(rc=rc):
                self.assertNotIn(standby_answer(), after_check(down=0, rc=rc))

    def test_blocked_says_why_for_the_notification(self):
        for down in (0, 2):
            with self.subTest(down=down):
                ends = answers(after_check(down))
                self.assertEqual(len(ends), 1, f"expected one answer, got {ends}")
                f = fields(ends[0])
                # The janitor fails on `blocked`, and the error reaches the phone.
                self.assertEqual(f.get("status"), "blocked")
                self.assertEqual(f.get("mode"), "ensure-off")
                self.assertIn("standby", f.get("blocked_by", ""))

    def test_the_check_never_hangs(self):
        _, calls, slept = check_standby(down=1000)
        self.assertTrue(calls, "the check never asked the hypervisor")
        for call in calls:
            # Without BatchMode a refused key waits for a password nobody types.
            self.assertIn("BatchMode=yes", call)
            timeout = re.search(r"ConnectTimeout=(\d+)", call)
            self.assertTrue(timeout and int(timeout.group(1)) <= 5, f"no short ConnectTimeout in {call!r}")
        # Long enough to see a wake-up right after the suspend, short enough
        # for a flow that runs every five minutes.
        self.assertGreaterEqual(slept, 45, f"watches only {slept}s")
        self.assertLessEqual(slept, 90, f"waits {slept}s")

    def test_a_skipped_standby_is_not_checked(self):
        # A guest running (the desktop guest left on after a game) or a terminal
        # open keeps the hypervisor on: no minute of waiting, and no alarm.
        nxt = [n for out in outputs(standby_request()) for n in out]
        self.assertEqual(len(nxt), 1, f"the standby request should go to one If node, it goes to {nxt}")
        for stdout in ("skip:100", "skip:terminals:1", "skip:task:vzdump"):
            with self.subTest(stdout=stdout):
                after = reachable(outputs(nxt[0])[branch(nxt[0], stdout)])
                self.assertNotIn(standby_check(), after)
                self.assertEqual([fields(n).get("hypervisor") for n in answers(after)], ["on"])


if __name__ == "__main__":
    unittest.main()
