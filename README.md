# homelab

GitOps config for two k3s clusters: `gw` (public edge, OVH VPS) and `home` (on-prem, bare metal).
Flux v2, Forgejo as git source, SOPS/age for secrets. Diagram: [`docs/architecture.svg`](docs/architecture.svg).

## Layout

One directory per Flux tenant, always the same shape:

```
clusters/<cluster>/<tenant>/
  ks.yaml            # Flux Kustomization (path, dependsOn, postBuild.substituteFrom)
  kustomization.yaml # plain kustomize, referenced by ../flux-system
  app/                # manifests (kustomization.yaml + resources)
  chart/              # only for dns — the one tenant still on Helm
```

`app/` is mandatory, not stylistic: kustomize's load restrictor rejects a bare file
outside the kustomization root but accepts a sibling directory with its own
`kustomization.yaml`. So `flux-system` can reference `../media`, never `../media/ks.yaml`.

```
clusters/<cluster>/
  flux-system/   bootstrap only — kubectl apply -k, no SOPS decryption available yet
  vars/          cluster-secrets (sops) — SECRET_DOMAIN, S3_*, RESTIC_PASSWORD, GW_<TENANT>_IP
  infra/         Cilium, cert-manager, storageclass, volsync, reloader, metrics-server
  <tenants...>
```

## Tenants

**gw**

| tenant | deps                | contents                                                                                 |
| ------ | ------------------- | ---------------------------------------------------------------------------------------- |
| `apps` | cluster-vars, infra | Gateway/gw-apps, http-redirect, lldap, pocketid, vaultwarden, wg                         |
| `dns`  | apps                | Helm chart (bind9), dynamic zone, TCPRoute/UDPRoute 53, HTTPRoute :2136 for ACME http-01 |

**home**

| tenant     | deps                | contents                                                                         |
| ---------- | ------------------- | -------------------------------------------------------------------------------- |
| `certs`    | infra, cluster-vars | cert-manager-webhook-ovh, wildcard ClusterIssuer                                 |
| `gateway`  | cluster-vars, certs | GatewayClass (cilium-gw), Gateway/gw, wildcard Certificate, http-redirect        |
| `apps`     | cluster-vars, certs | papra, syncthing + syncthing-discovery                                           |
| `media`    | cluster-vars        | jellyfin, sonarr, radarr, prowlarr, autobrr, flaresolverr, rclone-sync (CronJob) |
| `registry` | cluster-vars        | OCI registry — **no restic bucket, deliberately unbacked**                       |
| `unifi`    | cluster-vars        | unifi-os-server (+TCPRoute), unifi-http proxy (+HTTPRoute)                       |

## Patterns

- **Plain YAML + `postBuild.substituteFrom`** everywhere except `dns`. Helm survives there
  only because the zone ConfigMap does real computation (`range` over `.dns.nodes` / `.dns.apps`).
- **One `cluster-secrets` Secret per cluster**, not split ConfigMap/Secret. `.sops.yaml` has a rule
  for it ahead of the catch-all: `encrypted_regex: ^(data|stringData)$` so metadata stays readable.
- **Per-tenant Flux Kustomizations**, colocated with their manifests — keeps the blast radius
  boundary at the tenant, not the cluster.
- **`cluster-vars` has its own Kustomization**, not folded into `infra` — reconciles in seconds,
  doesn't queue behind Cilium/cert-manager. Can't live directly under `flux-system/` (bootstrapped
  with plain `kubectl apply -k`, can't decrypt SOPS).
- **Every stateful Namespace**: `kustomize.toolkit.fluxcd.io/prune: disabled` — survivability net,
  not a fix, for the self-referential prune hazard below.
- **Data PVs**: `reclaimPolicy: Retain` via `local-path-retain` storageclass, not the default
  `local-path` (Delete). Volsync `*-cache` PVs stay Delete by design.
- **Backups**: one `volsync.backube ReplicationSource` per stateful PVC, hourly, restic to OVH S3,
  `pruneIntervalDays: 14`. `registry` is the one exception — no bucket, see table above.
- **wg reresolve sidecar** (`clusters/gw/apps/app/wg.yaml`): re-runs `wg set wg0 peer … endpoint`
  every 30s from `wg show`, so a bind restart re-resolving the peer's hostname doesn't kill the
  tunnel. Needless without it: `wg-quick` resolves the endpoint once at startup only.
- **`$` is meaningful** once substitution is on. Only two `$$` escapes needed repo-wide (outside the
  `dns` chart): vaultwarden's `"^$"` regex, unifi's `echo $HOST_IP`.
- **`postBuild` is string substitution — it cannot indent.** Multi-line values (SSH keys) go
  base64-encoded in a `data:` field, never `stringData:`.

## Known hazards (read before touching a tenant)

1. **Self-referential prune window.** A tenant's Kustomization polls git on its own interval,
   independent of `flux-system`. If it reconciles a path-rename commit before `flux-system` does,
   it builds the OLD path against the NEW tree, sees only itself, and prunes everything else —
   including the Namespace, cascading to every PVC. Procedure for any path change:
   ```
   flux suspend kustomization <tenant>
   git push
   flux reconcile kustomization flux-system --with-source
   flux resume kustomization <tenant>
   ```
2. **Deleting a HelmRelease runs `helm uninstall`, which deletes its PVCs.** Sweep `keep` onto every
   chart resource (not just PVCs) by `kind:`, never by filename — a PVC inlined in a Deployment
   template will be missed by a `*/pvc.yaml` glob. Verify live on the cluster before removing
   anything from the chart, don't trust the diff.
3. **`bind` restarts on the first commit of each new UTC hour** (SOA serial = `{{ now | date
"2006010215" }}`, byte-identical render within the hour, Reloader fires on the boundary). That
   restart used to take wireguard down with it — fixed by the reresolve sidecar, not by touching DNS.
4. **Server-side apply ownership can go stale.** Resetting `managedFields` drops a claim but leaves
   the object owner-less; the next kustomize-controller apply that doesn't declare a field (e.g. an
   immutable `spec.volumeName`) then _removes_ it. Hand ownership back with an explicit
   `kubectl apply --server-side --field-manager=<name>` of just that field, don't patch it with its
   current value (no-op, transfers nothing).

## Operations

```
task templates:inventory   # decrypt secrets/inventory.sops.yaml -> .private/inventory.yaml
task gw:flux / home:flux   # bootstrap flux-system on a fresh cluster
task gw:cni / home:cni     # install Cilium + Gateway API CRDs
task home:bgp              # apply/reapply BGP config
task restic:cmd -- <args>  # restic against the shared S3 backend
task restic:s3 -- <args>   # aws s3 against the same bucket
task renovate:test|lookup|run
```

Verify before pushing a tenant change:

```
flux diff kustomization <tenant> --path ./clusters/<cluster>/<tenant>/app
```

Server-side dry-run including `postBuild` substitution — `kustomize build` alone can't catch a
missing `substituteFrom` or an unresolved `${VAR}`.

Renovate runs daily via Forgejo Actions (`.forgejo/workflows/renovate.yaml`) plus on push to
`renovate.json5`. Bootstrap version pins (Cilium, Gateway API) live as shell exports in `tasks/*.yaml`,
picked up by a custom regex manager — not a standard Renovate datasource.
