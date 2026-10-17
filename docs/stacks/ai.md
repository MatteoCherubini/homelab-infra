# AI stack

`stacks/ai/compose.yml` — Ollama, a local LLM runtime with a dedicated GPU.
It runs as a compose project of its own, `homelab-ai`, under its own systemd
unit: see [A project of its own](#a-project-of-its-own).

| Service | Role |
|---------|------|
| `ollama` | Local model inference over HTTP on port 11434 |

---

## Who can reach it

Only the server itself. The port is published on `127.0.0.1`, and n8n reaches
the service on the Docker network as `ollama:11434`.

Ollama has no authentication: anyone who can reach the port can run any model,
pull new ones and delete the existing ones. Published on every interface, that
was every device on the LAN and on the tailnet, while the only callers were n8n
and the health check. A week of its request log, read before closing it, showed
exactly those two.

From another machine, when it is really needed, an SSH tunnel does it without
opening anything:

```bash
ssh -N -L 11434:127.0.0.1:11434 <server>
```

---

## GPU reservation

Ollama holds an NVIDIA device reservation for one GPU with the `gpu`
capability, and it is the only container that holds one. Homepage used to take
a second reservation with the `utility` capability, for telemetry no widget
read; it was dropped, because it put the dashboard in the GPU's failure domain.

`make gpu-check` reports whether the NVIDIA runtime is visible at all, which is
the first thing to check when Ollama starts but answers slowly — it falls back
to CPU rather than failing outright, so the symptom is latency, not an error.

## A project of its own

A container with a GPU reservation that cannot start makes `docker compose up`
abort partway, and every service not started yet stays in `Created`. Inside
the main project that took n8n down with Ollama (below). So the root
`docker-compose.yml` does not include this stack: it runs as the project
`homelab-ai`, joins the main project's network as `external`, and has its own
unit. A GPU failure then fails `homelab-ai.service` and nothing else.

Every command runs from the repository root, so `.env` and relative paths
resolve as for the rest:

```bash
docker compose --project-directory . -f stacks/ai/compose.yml up -d
docker compose --project-directory . -f stacks/ai/compose.yml ps
```

`make up`, `down`, `restart`, `pull`, `ps`, `verify`, `health` and `check`,
the health check and the update checker ask both projects. `make test` fails
if a stack is left out of the root file without being a complete project of
its own, or without the tools knowing it.

`/etc/systemd/system/homelab-ai.service`:

```ini
[Unit]
Description=Homelab AI stack (Ollama and the GPU), apart from the other stacks
Requires=docker.service homelab-compose.service
After=docker.service homelab-compose.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/homelab-infra
ExecStart=/usr/bin/docker compose --project-directory . -f stacks/ai/compose.yml up -d --force-recreate
ExecStop=/usr/bin/docker compose --project-directory . -f stacks/ai/compose.yml down --timeout 30
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now homelab-ai
```

- `Requires=` and `After=` on `homelab-compose.service`: it starts after the
  main project, whose network it joins, and is stopped or restarted with it,
  first. `systemctl stop homelab-compose`, which the UPS handler runs, stops
  both; `needrestart` cycling the main unit cycles this one too, in order.
- The dependency runs one way: this unit failing never fails the main one.
- `sudo systemctl restart homelab-ai` touches Ollama alone.
- `--force-recreate`, because of what a failed start leaves behind: a container
  in `Created`, holding the id of the network as it was then. Stopping the main
  project removes that network and starting it makes a new one, and Compose
  (v5.5.1, `mustRecreate`) checks the network only of *running* containers. The
  old container would be started as it is and fail on the missing network, so
  the reboot that fixes a broken driver would leave Ollama down anyway.
  Recreating it at every start costs seconds; the models are on disk.

**The test of the failure.** First the order, with everything healthy:

```bash
sudo systemctl restart homelab-compose            # Ollama stops first, the rest restarts, Ollama comes back
systemctl is-active homelab-compose homelab-ai    # → active, active
```

Then the failure. The cause does not matter, only that the project's `up`
fails; the port Ollama publishes, taken on the host, does it with certainty
and without touching the driver. It needs the Docker userland proxy, which is
on unless `/etc/docker/daemon.json` sets `"userland-proxy": false`:

```bash
sudo systemctl stop homelab-ai                    # frees the port
python3 -m http.server 11434 --bind 127.0.0.1     # in a second terminal, left running
sudo systemctl start homelab-ai                   # → fails: the address is in use
sudo systemctl restart homelab-compose            # what needrestart did on 2026-09-21
systemctl is-active homelab-compose homelab-ai    # → active, failed
make healthcheck                                  # → only the two ollama rows in red
# stop the http.server, then:
sudo systemctl start homelab-ai                   # → active; make healthcheck all green
```

Run on 2026-10-17 with Compose 5.5.1, all three as expected: the ordered
restart came back whole; with the port taken the main unit restarted
`active` while `homelab-ai` stayed `failed`, and only the two Ollama rows of
the health check were red (35/2); with the container left `Created` on a
network that no longer existed, `systemctl start homelab-ai` recreated it and
the check went back to 37/0. A health check run in the first seconds after a
restart also shows n8n, Vaultwarden and Excalidraw still starting: run it
again after half a minute.

## Storage

Models live in `${DATA_ROOT}/ollama/data`, mounted at `/root/.ollama`. This is
by far the largest data directory in the installation — currently around 15 GB
— and it is **not** covered by the repository in any form.

That is also why Ollama is pinned to `latest` despite not being stateless: the
models live in a volume the image does not own, so rolling the image back costs
nothing. See [updating](../updating.md).

## Unattended driver upgrades will break this

The GPU is the one part of this host that an automatic security update can
take away underneath a running container.

On 2026-09-21 `unattended-upgrades` installed `nvidia-driver-580` 580.178.04
while the kernel module loaded at boot was still 580.173.02. Two things broke
at once:

- `nvidia-smi` started failing with `Driver/library version mismatch`, because
  the kernel module and the userspace libraries no longer matched;
- `nvidia-persistenced` stopped and its socket directory disappeared, so the
  NVIDIA container runtime could no longer satisfy the bind mount it needs.
  Every container with a GPU reservation then failed to start with:

  ```
  failed to fulfil mount request:
  open /run/nvidia-persistenced/socket: no such file or directory
  ```

`needrestart` cycled `homelab-compose.service` moments later, which restarted
the whole stack; the two GPU containers could not come back, the unit was left
`failed`, and n8n and its worker were left in `Created` because the `up` call
aborted partway.

**The fix is a reboot**, which the upgrade had already flagged in
`/var/run/reboot-required` — a new kernel had been installed too. A reboot
loads the matching module, restarts `nvidia-persistenced`, and
`homelab-compose.service` brings the stack back because it is enabled.

Without rebooting, `sudo systemctl start nvidia-persistenced` followed by
`sudo systemctl restart homelab-ai` gets Ollama running again, but the
module/library mismatch remains: inference falls back to CPU rather than
failing loudly, so the symptom is latency, not an error.

Two things changed after this, so that the same failure stops inference and
nothing else: Ollama runs as [a project of its own](#a-project-of-its-own),
and Homepage no longer holds a GPU reservation, so the dashboard stays up
exactly when it is wanted.

## Keep-alive

`OLLAMA_KEEP_ALIVE=5m` keeps a model resident for five minutes after its last
request. Longer holds VRAM against an idle homelab; shorter pays the load cost
on every call from a scheduled workflow.

## Who calls it

The n8n update-checker workflow uses it to rank available updates by risk.
It reaches it by name on the Docker network (`http://ollama:11434`), which the
separate project keeps. When Ollama does not answer, the list of updates still
goes out on its own branch, and the ranking node continues on failure
(`continueOnFail`), so a second notification says "No response from Ollama"
instead of the run ending in an error nobody sees.

That output is an aid, not an authority: the model has no access to upstream
release notes and reasons from version numbers alone. It called a Forgejo patch
release harmless on a day when that patch closed two remote code execution
holes. [updating](../updating.md) covers why the final decision stays with a
person.
