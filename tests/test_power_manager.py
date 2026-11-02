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
"""

import json
import os
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


if __name__ == "__main__":
    unittest.main()
