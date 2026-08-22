# Migration k3s → Talos

Runbook. Two clusters, `home` (bl3) then `gw` (Hetzner Cloud), in that order and never in parallel.

Reference material lives in [README.md](README.md), and this file does not restate it: the **canonical bootstrap sequence** and why each imperative step is irreducible, what counts as a secret in this repo, the verified bl3 hardware, the media-volume adoption, the Hetzner specifics. Read "Bootstrap order" there once before starting; the phases below are that sequence with the per-cluster detail attached.

---

## What can actually hurt

Read these before anything else. Everything after is mechanics.

### 1. ✅ The restore path is proven — manifest in Phase 0.1

Exercised end to end on the live cluster on 2026-08-22 against `autobrr-config`: restored into a scratch PVC, verified the contents, cleaned up. 8 files, 113.1 MiB, `autobrr.db` a valid SQLite file with mtimes preserved — byte-for-byte what the `ReplicationSource` had written minutes earlier.

There are still **zero `ReplicationDestination` objects committed** to the repo, so the manifest below is the only record of how to do it. Keep it.

### 2. 🔴 `zen` is the branch the running clusters follow

`clusters/*/flux-system/gitrepository.yaml` → `ref.branch: zen`. Merging this branch wholesale would push, onto a **running k3s**:

| Change                                             | Effect on live k3s                                                                       |
| -------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `cilium.yaml` → `k8sServiceHost: localhost:7445` | 🔴 KubePrism does not exist on k3s. Cilium loses the apiserver. Cluster networking dies. |
| hostPath `/var/mnt/media`                          | Media stack fails to start — the path does not exist on Ubuntu.                          |
| `local-path-provisioner` HelmRelease               | Fights k3s's built-in provisioner over the `local-path` StorageClass.                    |

So: **`clusters/gw/**`must not reach`zen` while the old gw is running.\*\* Flux scopes by path, so splitting by path is clean. In practice the old gw is powered off just before that merge (Phase 2, step 4), which makes the window trivial.

### 3. ✅ Two PVCs have no backup — decided, expendable

`registry-data` (re-pullable images) and `jellyfin-cache` (a cache). Both accepted as losses. No action.

`/media` (1.4 TB) is not covered either, which is why it is adopted rather than reformatted — see README.

### 4. ✅ Issuers are chart-created, and the ordering already holds

I initially read gw's `ClusterIssuer le-prod` as applied by hand and missing from git, and wrote a patch to commit it. That was wrong. The chart creates it: `clusters/gw/infra/cert-manager-webhook-ovh-values.sops.yaml` carries an `issuers:` block with `create: true` for the prod and staging issuers both, and the live objects are labelled `helm.toolkit.fluxcd.io/name: cert-manager-webhook-ovh`. My sweep for unmanaged objects only tested the kustomize label, never the helm one. Committing that patch would have given the same objects two owners.

What actually has to hold for gw to rebuild from git, both already true:

- **`sops-age` before anything reconciles.** The webhook's values are SOPS-encrypted, so without that secret the chart installs with no `issuers:` and nothing creates an issuer — which looks exactly like a cert-manager bug. `go-task gw:flux` creates it before applying any Kustomization.
- **The webhook up before the first `Certificate`.** `infra` has `wait: true`, `apps` has `dependsOn: [cluster-vars, infra]`, and `dns` has `dependsOn: [apps]`. Airtight.

## Phase 0 — de-risk, touching nothing

Nothing here mutates a cluster. All of it can be done today.

### 0.1 The verified restore manifest

This exact shape was run against `autobrr-config` and worked. Reuse it for every PVC in Phase 1.8, changing only the four names.

```yaml
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: restore-<pvc>
  namespace: <ns>
spec:
  trigger:
    manual: restore-once # fires once, then waits; no schedule
  restic:
    repository: restic-config-<pvc> # the secret flux already creates
    copyMethod: Direct # matches the sources
    destinationPVC: <pvc> # the real PVC, workload scaled to 0
    cacheCapacity: 2Gi
    cleanupCachePVC: true # or volsync leaves its cache PVC behind
    cleanupTempPVC: true
```

Completion looks like this — check `result`, not just `lastSyncTime`:

```sh
kubectl -n <ns> get replicationdestination restore-<pvc> \
  -o jsonpath='{.status.latestMoverStatus.result}{"\n"}'
# Successful
```

Notes from actually doing it:

- the mover took ~20 s for 113 MiB; it schedules its own pod, nothing to babysit
- a `ReplicationDestination` only **reads** the restic repo — it does not prune or write, so running one against a live repo is safe
- `local-path` is `WaitForFirstConsumer`, so the target PVC stays `Pending` until the mover pod schedules. That is normal, not a failure.
- the namespace needs `volsync.backube/privileged-movers: "true"`. `apps`, `media` and `unifi` already have it; **`registry` does not** — relevant if you decide to start backing up `registry-data`.
- delete the `ReplicationDestination` when done, or it sits there holding the manual trigger

### 0.2 Verify the backups are readable, not just present

⚠ `restic:cmd` takes the **repository path first**, then the restic subcommand — `CLI_ARGS` is appended to the endpoint. `go-task restic:cmd -- snapshots` silently builds a nonsense repo URL.

The bucket prefixes are `RESTIC_BUCKET_*` in `cluster-secrets`, so read them rather than retyping them — that keeps the one copy in the encrypted file:

```sh
sec=clusters/home/vars/app/cluster-secrets.sops.yaml
MEDIA=$(sops -d $sec | yq -r '(.stringData // .data).RESTIC_BUCKET_MEDIA')
APPS=$(sops  -d $sec | yq -r '(.stringData // .data).RESTIC_BUCKET_APPS')
UNIFI=$(sops -d $sec | yq -r '(.stringData // .data).RESTIC_BUCKET_UNIFI')
```

There is one repository per PVC — twelve of them — so sweep the lot:

```sh
for r in \
  "$MEDIA"/{autobrr,jellyfin,prowlarr,radarr,sonarr}-config \
  "$APPS"/{papra-docs,syncthing,syncthing-discovery,lldap,pocketid,vaultwarden} \
  "$UNIFI"/unifi-os-pvc
do
  echo "== $r"
  go-task restic:cmd -- "$r" snapshots --latest 1
done
```

`check --read-data-subset=5%` is worth running on the ones that matter most, same syntax:

```sh
go-task restic:cmd -- "$APPS"/vaultwarden check --read-data-subset=5%
```

### 0.3 Second age recipient

Not blocking, but the window of single-point-of-failure should be short. `sops updatekeys` works retroactively, so this can happen any time.

```sh
age-keygen -o /somewhere/offline/backup.age
# add the public key to every rule in .sops.yaml, then:
for f in $(git ls-files | grep -E '\.sops\.(yaml|rsc)$' | grep -v '^\.sops\.yaml$'); do
  sops updatekeys -y "$f"
done
```

### 0.4 Capture what only the live machines can tell you

**bl3** is already captured in `talenv`, read off the host. Nothing to do.

**gw** needs nothing here any more: blue/green means the old server is never wiped, and the new server's addressing is only knowable once it exists. That capture moved to Phase 2.3 step 1.

The shape is always the same: Hetzner Cloud delegates a /64 per server, the host takes `::1`, the gateway is `fe80::1`. Only the prefix changes. The current server's is in `talos/gw/talenv.sops.yaml` as `GW_ADDR6`; the new one comes from `hcloud server describe`.

### 0.5 Static checks green

```sh
go-task secrets:check
go-task talos:config CLUSTER=home
go-task talos:config CLUSTER=gw
```

`secrets:check`: every `.sops.*` file really is encrypted; no credential-shaped literal sits in a plaintext file; no address literal appears in a doc; no doc repeats a value that exists only encrypted. `talos:config`: both clusters' machine configs generate and validate. Everything else flux tells you at the next reconcile.

### 0.6 Nothing to decide on `registry-data`

Accepted as an expendable loss, along with `jellyfin-cache`. If that ever changes: the `registry` namespace lacks the `volsync.backube/privileged-movers: "true"` annotation, so a `ReplicationSource` there would never start its mover.

---

## Phase 1 — bl3

### 1.1 Split the branch by cluster

```sh
git checkout talos
git checkout -b talos-home
# keep only home-scoped changes; leave clusters/gw/** and talos/gw/** for Phase 2
```

Everything shared — `talos/`, `tasks/`, `.sops.yaml`, `renovate.json5`, `.gitignore` — is inert on a running cluster and can go in this first merge safely. Only `clusters/gw/**` must wait.

⚠ `talos/gw/talenv.sops.yaml` carries the **old** server's `GW_ADDR6`, so keep `talos/gw/` out of the home branch too if you would rather not merge a value you are about to change.

### 1.2 Final backup, then verify it

```sh
# Force a run of every ReplicationSource rather than waiting for the hourly
# schedule. `-o name` drops the namespace, so carry it explicitly.
kubectl get replicationsource -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
| while read ns name; do
    kubectl -n "$ns" patch replicationsource "$name" --type merge \
      -p '{"spec":{"trigger":{"manual":"pre-migration"}}}'
  done

# Every RESULT must read Successful, and every LAST must be from this run.
kubectl get replicationsource -A -o custom-columns=\
NS:.metadata.namespace,NAME:.metadata.name,LAST:.status.lastSyncTime,\
RESULT:.status.latestMoverStatus.result
```

⚠ Switching a `ReplicationSource` to a manual trigger **stops its schedule**. Revert it once the backup is confirmed, or that PVC silently stops being backed up:

```sh
kubectl -n <ns> patch replicationsource <name> --type json \
  -p '[{"op":"remove","path":"/spec/trigger/manual"},
       {"op":"add","path":"/spec/trigger/schedule","value":"0 * * * *"}]'
```

In practice flux will put the schedule back on its next reconcile, since the manifests in git carry it — but do not rely on that if flux is suspended.

### 1.3 Render, then build the ISO

```sh
go-task talos:config CLUSTER=home  # clusterconfig/ — everything below reads it
go-task talos:url CLUSTER=home     # take the "image" URL — an .iso for home
```

Mount it through the **JetKVM virtual media** — bl3 has one, so this is remote. No physical trip, and you keep a console if the network config is wrong.

### 1.4 Point of no return

Boot the ISO. The node comes up in maintenance mode with a **DHCP address shown on the console** — not the static address in talenv.

```sh
go-task talos:cmd:apply-insecure CLUSTER=home
# run the printed command with -n <maintenance-ip>
```

The node installs to the nvme and reboots.

⚠ The 4 TB USB disk is adopted, not formatted. Confirm after boot, before doing anything else:

```sh
BL3=$(sops -d talos/home/talenv.sops.yaml | yq -r .BL3_ADDR6)
talosctl -n "$BL3" get volumestatus e-media
talosctl -n "$BL3" ls /var/mnt/media
```

If `/var/mnt/media` is empty, **stop** — something provisioned instead of adopting.

### 1.5 Bootstrap etcd

```sh
go-task talos:cmd:bootstrap CLUSTER=home
```

**Once. One node. Ever.** Then:

```sh
go-task talos:kubeconfig CLUSTER=home
kubectl get nodes            # NotReady is expected: no CNI yet
```

### 1.6 CNI, then BGP

```sh
go-task home:cni
kubectl get nodes            # Ready now
go-task home:bgp
```

Verify the peering from the router, **read-only** (`.private/docs/mikrotik.md` doctrine):

```
/routing bgp session print
/ip route print where bgp
```

And `ip route get <ip>` before concluding anything about reachability — the ICMP-redirect cache lies for ~5 min.

### 1.7 Merge, then flux

```sh
git checkout zen && git merge talos-home && git push
go-task home:flux
```

Watch it converge:

```sh
flux get all -A
kubectl get pods -A
```

`home:cni` fed helm the same `spec.values` flux is about to apply, so the handover is a values no-op and nothing needs restarting. If Cilium misbehaves anyway, that assumption is the first thing to check:

```sh
helm -n kube-system get values cilium > /tmp/live.yaml
bash tasks/cilium-values.sh home | diff - /tmp/live.yaml
# non-empty diff → kubectl -n kube-system rollout restart deploy/cilium-operator ds/cilium-envoy
```

### 1.8 Restore the PVCs

For each backed-up PVC, using the manifest proven in Phase 0.1:

1. scale the workload to 0
2. apply the Phase 0.1 `ReplicationDestination`, `destinationPVC` on the real PVC
3. wait for `.status.latestMoverStatus.result == Successful`
4. delete the `ReplicationDestination`
5. scale the workload back up

Order matters for nothing here except doing `sonarr`/`radarr`/`prowlarr` before checking that the media library reconciles.

### 1.9 Acceptance

- `talosctl -n <node> health` clean
- `kubectl get nodes -o wide` shows **both** address families
- `kubectl get svc kubernetes` has a **v6** ClusterIP — IPv6 is the primary family
- a pod gets an IP inside **both** `POD_CIDR4` and `POD_CIDR6` from `talos/home/talenv.sops.yaml`
- `kubectl get pvc -A` all `Bound` → local-path-provisioner works under Talos PodSecurity
- `kubectl get gateway -A` has an LB IP, and HTTPS works end to end from the LAN
- **Jellyfin hardware transcode works** — that is the canary for the `i915` extension
- `/var/mnt/media` still holds 1.4 TB

---

## Phase 2 — gw, on a new VPS

A second Hetzner Cloud server, built alongside the current one. The old gw is **powered off before the merge**, so the two never serve at once — which removes the shared-restic and duplicate-certificate problems entirely. Rollback is powering it back on.

### What depends on gw's IP

Same shape as §0.4: a delegated /64, host on `::1`, gateway `fe80::1`. The current values are `GW_ADDR6` in `talos/gw/talenv.sops.yaml`; the new server gets a different prefix.

| Name                   | Points at                              | Moves?                              |
| ---------------------- | -------------------------------------- | ----------------------------------- |
| `gw`, `pass.s`, `auth` | the public IPs                         | yes                                 |
| `gw6`                  | the public IPv6                        | yes — this is the WireGuard cutover |
| `lldap`, `http2136`    | the wg VIP, `clusters/gw/infra/ippool.sops.yaml` | no, follows the tunnel    |

**The WireGuard cutover needs no router change.** home-router's peer dials a name, not an address: its `endpoint-address` is `WG_ENDPOINT_FQDN`. Repointing that record moves the tunnel, so the read-only doctrine on the MikroTik holds.

⚠ `http2136` is how **home** solves DNS-01. While the tunnel is down, home cannot issue or renew certificates. Don't schedule this near a home certificate expiry.

### Steps

1. **Create the server, capture its facts.**

   ```sh
   hcloud server describe <name> -o json | jq '.public_net'
   ```

   Replace `GW_ADDR6` in `talos/gw/talenv.sops.yaml` (`sops set`, or `sops edit`) with `<prefix>::1` — it still holds the **old** server's address, and it feeds both the static v6 address and every `talosctl -n`. Confirm `GW_INSTALL_DISK` in rescue mode while you are there.

2. **Build the image.** No custom-ISO upload on Hetzner:

   ```sh
   go-task talos:url CLUSTER=gw          # "image" is the .raw.xz for hcloud
   ```

   Throwaway server → Hetzner Rescue System → `lsblk` to confirm the target device (that is also how you confirm `GW_INSTALL_DISK`) → `wget -O- <raw.xz> | xz -d | dd of=<disk> bs=4M status=progress` → snapshot → build the real gw from it.

3. **`apply-config --insecure` → `bootstrap` → `kubeconfig` → `go-task gw:cni`.** Same as bl3, same warning on `bootstrap`.

   Sanity check before `gw:cni`: `talosctl -n <ip> get links`. `cilium.yaml` matches the public NIC as `en+`/`eth+` rather than by name, which covers the `enp*`/`ens*`/`eth*` spread — but if Talos named it something else entirely, Cilium puts no NodePort/LB translation on it and nothing answers on 80/443.

4. **Power off the old gw.** Everything public goes down here. Keep the server, do not delete it.

5. **Merge `clusters/gw/**`to`zen`**, then `go-task gw:flux`.

6. **Restore** `lldap`, `pocketid`, `vaultwarden` with the Phase 0.1 manifest.

7. **Flip DNS**: `gw`, `pass.s`, `auth`, then `gw6` last — that moves the tunnel and brings back `lldap` and `http2136`.

8. **Acceptance**: real certificates issued, `curl -I` on the vaultwarden vhost (`cluster-secrets`), `talosctl -n <gw> get links wg0`, `ping6` the wg address from home.

9. **The ingress firewall, last.** Not in git until this step on purpose — everything under `patches/` is applied on the next render, so a rule set committed early would ship before you are ready. Append the documents below to `patches/gw-node.yaml`, **with the Hetzner console open**, re-run `go-task talos:config CLUSTER=gw`, apply, and check in this order: `talosctl get nftableschains`, a public `curl`, then `talosctl version` over wg.

   The unknown is whether Cilium's eBPF NodePort path (`loadBalancerClass io.cilium/node`) obeys or bypasses the nftables rules Talos installs. Getting it wrong locks out a host whose only other door is that console.

   `WG_SUBNET6` and `WG_SUBNET4` are talenv keys, so this pastes in as-is — the render substitutes them. YAML anchors do not cross document boundaries, so the tunnel subnets are written out each time:

   ```yaml
   ---
   apiVersion: v1alpha1
   kind: NetworkDefaultActionConfig
   ingress: block
   ---
   # Only the tunnel may reach the control plane.
   apiVersion: v1alpha1
   kind: NetworkRuleConfig
   name: apid
   portSelector: { ports: [50000], protocol: tcp }
   ingress:
     - subnet: ${WG_SUBNET6}
     - subnet: ${WG_SUBNET4}
   ---
   apiVersion: v1alpha1
   kind: NetworkRuleConfig
   name: kube-apiserver
   portSelector: { ports: [6443], protocol: tcp }
   ingress:
     - subnet: ${WG_SUBNET6}
     - subnet: ${WG_SUBNET4}
   ---
   apiVersion: v1alpha1
   kind: NetworkRuleConfig
   name: kubelet
   portSelector: { ports: [10250], protocol: tcp }
   ingress:
     - subnet: ${WG_SUBNET6}
     - subnet: ${WG_SUBNET4}
   ---
   apiVersion: v1alpha1
   kind: NetworkRuleConfig
   name: etcd
   portSelector: { ports: [2379, 2380], protocol: tcp }
   ingress:
     - subnet: ${WG_SUBNET6}
   ---
   # home-router's public IP is dynamic; the peer key authenticates.
   apiVersion: v1alpha1
   kind: NetworkRuleConfig
   name: wireguard
   portSelector: { ports: [51820], protocol: udp }
   ingress:
     - subnet: 0.0.0.0/0
     - subnet: ::/0
   ---
   apiVersion: v1alpha1
   kind: NetworkRuleConfig
   name: http-public
   portSelector: { ports: [80, 443], protocol: tcp }
   ingress:
     - subnet: 0.0.0.0/0
     - subnet: ::/0
   ```

10. **After a week**: delete the old server, then remove what only it needed — the duplicated `WG_*` keys in `clusters/gw/vars/app/cluster-secrets.sops.yaml`, `tasks/wg-host.sh`, the `gw:wg` task, and `gw:kubeconfig` (it SSHes in as root, which Talos has no answer for — `talos:kubeconfig` replaces it).

    `wg-host.sh` stays until that point on purpose: it is what configures the tunnel on the old server, so deleting it earlier would break the rollback.

## Rollback

**bl3, before `bootstrap`:** nothing is lost. Re-flash Ubuntu, restore PVCs from restic. The media disk was never touched.

**bl3, after flux has converged:** rolling back means rebuilding k3s and restoring again. Cheaper to fix forward.

**gw:** power the old server back on, flip four DNS names back.

**Both:** `zen` is a merge away from its pre-migration state, so reverting the manifests is one `git revert`. The cluster underneath is what is expensive, not the config.

---

## After

- delete the throwaway Hetzner server and the old gw
- add a `ReplicationSource` for `registry-data` if you decided it matters
- schedule `go-task talos:etcd:snapshot CLUSTER=gw`; there was no etcd backup before
