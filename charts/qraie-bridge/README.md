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

**Three services all implicitly claim the Ingress's `/` path**: `bridge`
(no `VIRTUAL_PATH` in the source, defaults to root), `iot-broker-web` (same),
and `radicale` (`VIRTUAL_PATH` was commented out). The original
`nginx-proxy`-based compose setup had the exact same ambiguity — whichever
one "won" depended on registration order, not something explicit. This chart
renders all three, unmodified, so the conflict is visible (`kubectl get
ingress -o yaml` will show three `path: /` rules for one host) rather than
silently resolved by me guessing. Pick the one that should actually own `/`
and change the other two's `services[].ingress.path` before a real rollout.

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
  ingress: { enabled: bool, path: string, pathType: Prefix }
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
