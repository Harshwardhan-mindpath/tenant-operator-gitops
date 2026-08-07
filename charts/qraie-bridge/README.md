# qraie-bridge

Converted from the `prototype-bridge` docker-compose stack (~40 services) into
one data-driven Helm chart: `values.yaml` has a `services:` list (one entry
per compose service), and generic `templates/deployment.yaml` /
`service.yaml` / `ingress.yaml` loop over it. This mirrors how
`tenant-operator` already deploys per-tenant workloads (see
`poc/chart-workplace` for the simpler nginx example) — install this chart
once per tenant via Argo CD, with a per-tenant values file overriding
`global.tenantId`/`global.domain` and any image tags that differ.

## What changed in the conversion (read before deploying)

**Blue/green collapsed to one Deployment per service.** The compose file
defined `_blue`/`_green` pairs of nearly every service (a manual traffic-swap
pattern). Kubernetes rolling updates make that redundant — `image.tag` is
just a value now; swap it and roll. Only the `_blue` variant's config was
kept. If you actually need live A/B traffic splitting later, use Argo
Rollouts on top of this chart rather than reintroducing parallel stacks.

**`/var/run/docker.sock` was deliberately NOT carried over**
(`bridge-cp-conductor`, `erep-server`). Mounting the host's Docker socket
into a pod is equivalent to granting that pod root on the node it's
scheduled on — unacceptable in a shared multi-tenant cluster. Whatever these
two services used it for (spinning up sibling containers, most likely)
needs a real redesign: the Kubernetes Jobs API with a narrowly-scoped
ServiceAccount/Role is the standard replacement, but that's an application
code change, not something this chart can paper over. Both services still
have their `DOCKER_ENABLED`/related env vars for parity, but the actual
capability is gone until you make that change.

**Ingress routing was rebuilt from the real `nginx.conf`, not guessed from
compose env vars.** The compose file's `VIRTUAL_HOST`/`VIRTUAL_PATH` env vars
(read by `nginx-proxy`, the auto-config-generator sidecar the original VM
setup used) made it look like ~26 services were externally exposed,
including three all implicitly claiming `/` (`bridge`, `iot-broker-web`,
`radicale`). Once the actual `nginx.conf` running on the VM was available,
it showed only **9 services are actually reachable from outside**:

| External path | Service | Real nginx.conf rewrite |
|---|---|---|
| `/` | `bridge` | none (`proxy_pass` had no URI — full path passthrough) |
| `/controlopsv2/api/` | `bridge-cp-conductor` | strip prefix entirely |
| `/organization/wfm/api/` | `wfm-api-gateway` | strip prefix entirely |
| `/galaxy/slmapi/` | `mcp-client` | strip prefix entirely |
| `/prism-ui` | `prism-ui` | strip prefix, replace with `/` |
| `/prism/api` | `prism-backend` | strip prefix, replace with `/` |
| `/prism-scanner` | `prism-scanner` | strip prefix, replace with `/` |
| `/acl_server/api` | `acl-server` | strip prefix, replace with `/api` |
| `/scheduler-agent/api` | `scheduler-agent` | strip prefix, replace with `/api` |

Every other service (`controlops-server`, `erep-server`,
`qraie-api-gateway`, `qraie-ui`, `admin-panel`, `wfm-ui`, `tranops-ui`,
`tranops-backend`, all five `iot-broker-*`, `enrollment-api`, `voxflow`,
`radicale`) has **no Ingress at all** now — they were never actually in the
real routing, only reachable internally via Service DNS (several of them
reference each other that way already, e.g. `scheduler-agent`'s
`RADICALE_BASE_URL: http://radicale:5232`).

**Why one Ingress object per exposed service, not one shared Ingress:**
`nginx.ingress.kubernetes.io/rewrite-target` is set at the Ingress *object*
level, not per path rule — since these 9 services need three different
rewrite behaviors (none, strip-to-`/`, strip-to-`/api`), they can't share one
Ingress and still rewrite correctly per path. `templates/ingress.yaml`
renders one Ingress per exposed service instead; each with the annotation
its own `services[].ingress.rewriteTarget` needs. The regex path
(`<prefix>(/|$)(.*)`) and `rewrite-target: <target>/$2` pairing exactly
reproduces nginx's own prefix-matching + `proxy_pass` URI-substitution
behavior — see the per-service comments in `values.yaml` for the specific
`location`/`proxy_pass` line each one was derived from.

**TLS and security headers** (`global.tls.*`, `global.securityHeaders`)
reproduce the source `nginx.conf`'s HTTPS server block: the same
`add_header` lines (via `more_set_headers` in an ingress-nginx
`configuration-snippet`, since `headers-more` ships built into ingress-nginx)
and TLS termination against a Secret instead of a cert file on disk. The
HTTP→HTTPS redirect and Let's Encrypt ACME-challenge handling from the
source config aren't reproduced here on purpose: ingress-nginx redirects to
HTTPS automatically once a `tls:` block is present (no extra config needed),
and cert issuance/renewal is cert-manager's job in Kubernetes — it manages
its own challenge routing, so there's no `.well-known/acme-challenge`
location to hand-roll. `global.tls.secretName` just needs to point at
whatever Secret cert-manager (or you, manually) produces.

**`scheduler-agent`'s `PRISM_BASE_URL`** pointed at `http://event-manager:4000`
in the source compose file, but no `event-manager` service exists anywhere
in it — a dangling reference. This chart points it at `prism-backend:28078`
instead (best guess based on naming) — please confirm that's actually
correct.

**Host bind-mounts became one of three things:**
- Named compose volumes (`bridge-cp-wtl-sr-instances`, `redis-data`,
  `voxflow_agents`, `voxflow_mcp`) → PVCs, see `persistence:` in values.yaml.
- Per-service writable data dirs (attachments, generated-ereps, logs,
  prism-videos, deepface/db caches) → PVCs, same section.
- **Static, pre-populated config** (`radicale`'s `./config` and `./rights`
  directories) → this chart can't invent their contents. Create ConfigMaps
  yourself and point `radicale.configConfigMapName`/`rightsConfigMapName` at
  them:
  ```bash
  kubectl create configmap radicale-config --from-file=./radicale/config -n <tenant-ns>
  kubectl create configmap radicale-rights --from-file=./radicale/rights -n <tenant-ns>
  ```
  `bridge-cp-conductor`/`bridge-cp-redis`'s `/opt/bridge-cp-redis/dispatcher`
  host mount falls in this same category and is currently a TODO (see the
  comments in `values.yaml`) — nothing is mounted there yet.

**Plaintext secrets were kept as-is for parity** (DB passwords, JWT
secrets, API keys — grep `values.yaml` for the `NOTE: plaintext` comments).
Six services already had `/vault/secrets:/vault/secrets:ro` mounted in the
source compose file (`bridge-cp-conductor`, `bridge`, `prism-backend`,
`voxflow`, `scheduler-agent`, `radicale`) — those get
`services[].vault.enabled: true` here, wired through the same Vault Agent
Injector pattern already proven out for `poc/chart-workplace` and
`tenant-operator` itself (see those for the Vault policy/role setup
commands). The apps are expected to read `/vault/secrets/*` directly, same
as the compose file already assumed. Move the remaining plaintext values to
Vault the same way before any real deployment.

## Values schema (per `services[]` entry)

```yaml
- name: string              # k8s resource name + Service DNS name
  enabled: true              # set false to skip this service entirely
  image: { repository, tag }
  command: []                # optional, overrides entrypoint
  args: []
  port: int                  # container port; 0 = no Service (internal-only, no other service reaches it by name)
  replicas: 1
  useCommonEnv: true          # false = don't merge global.commonEnv in
  env: {}                     # service-specific, overrides commonEnv on conflicts
  ingress: { enabled: bool, path: string, rewriteTarget: string }   # rewriteTarget "" = no rewrite, passthrough
  vault: { enabled: bool }    # Vault Agent Injector, uses global.vault.role
  persistentVolumeMounts:     # references persistence.<key> PVCs (chart-level, shared across services if reused)
    - { name: <persistence key>, mountPath: string, subPath: "" }
  extraVolumes: []            # raw k8s volume specs (bring-your-own ConfigMaps/Secrets)
  extraVolumeMounts: []
  dnsConfig: { nameservers: [] }   # additive to ClusterFirst, not a replacement
  healthCheck: { path: string, port: int }   # adds readiness+liveness httpGet
  resources: {}                # overrides global.defaultResources
```

## Deploy (per tenant, via Argo CD)

Same pattern as `poc/chart-workplace`: point an Argo CD Application (or the
tenant-operator's ApplicationSet) at this chart's path with a per-tenant
values file overriding at minimum:

```yaml
global:
  tenantId: <tenant-id>
  domain: <tenant-id>.your-domain.com
  tls:
    enabled: true
    secretName: <tenant-id>-tls   # e.g. produced by a cert-manager Certificate
```

## Verify

```bash
helm lint charts/qraie-bridge
helm template test charts/qraie-bridge | less
# sanity-check the Ingress path conflicts and resource counts:
helm template test charts/qraie-bridge | python3 -c "
import yaml, sys
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
from collections import Counter
print(Counter(d['kind'] for d in docs))
"
```
