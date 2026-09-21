# Tools stack

`stacks/tools/compose.yml` — small, stateless utilities.

| Service | Role |
|---------|------|
| `excalidraw` | Collaborative whiteboard |

---

Excalidraw stores its drawings in the browser's local storage, not on the
server. The container holds no state, which is why it is classified
`stateless` in `services_metadata.json` and tracked on `latest`: there is no
data to migrate and nothing to roll back to.

This stack exists as the place where that kind of service goes, so that adding
one later does not mean deciding where it belongs.
