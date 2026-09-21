# AI stack

`stacks/ai/compose.yml` — Ollama, a local LLM runtime with a dedicated GPU.

| Service | Role |
|---------|------|
| `ollama` | Local model inference over HTTP on port 11434 |

---

## GPU reservation

Ollama holds an NVIDIA device reservation for one GPU with the `gpu`
capability. Homepage takes a reservation on the same device with only the
`utility` capability, which is enough to read telemetry for the dashboard
without competing for compute.

`make gpu-check` reports whether the NVIDIA runtime is visible at all, which is
the first thing to check when Ollama starts but answers slowly — it falls back
to CPU rather than failing outright, so the symptom is latency, not an error.

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
`docker compose up -d` gets the containers running again, but the
module/library mismatch remains: inference falls back to CPU rather than
failing loudly, so the symptom is latency, not an error.

Worth knowing for this host: the two services affected are Ollama and
Homepage, because Homepage also holds a reservation on the same GPU. A GPU
problem therefore takes out the dashboard as well as inference, which is
exactly when you would want the dashboard.

## Keep-alive

`OLLAMA_KEEP_ALIVE=5m` keeps a model resident for five minutes after its last
request. Longer holds VRAM against an idle homelab; shorter pays the load cost
on every call from a scheduled workflow.

## Who calls it

The n8n update-checker workflow uses it to rank available updates by risk.

That output is an aid, not an authority: the model has no access to upstream
release notes and reasons from version numbers alone. It called a Forgejo patch
release harmless on a day when that patch closed two remote code execution
holes. [updating](../updating.md) covers why the final decision stays with a
person.
