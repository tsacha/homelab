# Talos

**Migrating from k3s? Start with [MIGRATE.md](MIGRATE.md).** This file is the reference; that one is the ordered runbook.

Two clusters, one layout each:

```
talos/<cluster>/
  talenv.sops.yaml      SOPS — addresses, CIDRs, disks, interfaces, wg keys
  talsecret.sops.yaml   SOPS — the root of trust (talosctl secrets-bundle format)
  schematic.yaml        Image Factory customization; schematic.id is its POSTed hash
  patches/              config patches with ${VAR} holes — everything here is applied
  clusterconfig/        generated, gitignored, disposable
```

No talhelper — it was archived upstream on 2026-08-26 and this repo no longer depends on any third-party generator. `tasks/talos-render.sh` does the whole job with `talosctl` itself: it re-executes under `sops exec-env talenv.sops.yaml`, substitutes with `envsubst` exactly the `${VARS}` that appear in `patches/` (an unset one fails the render, it never passes through), feeds everything to `talosctl gen config --with-secrets`, validates with `talosctl validate`, and points the talosconfig at the node. Substitution is textual, so `${BL3_ADDR6}/64` works and so does an inline JSON list (`WG_ALLOWED`).

Everything in `clusterconfig/` is derived — delete it whenever, `go-task talos:config` rebuilds it. `patches/cluster.yaml` carries the cluster-wide intent (subnets, CNI none, cert SANs), `patches/<node>-node.yaml` the per-node documents (install, hostname, links, wireguard); `patches/controlplane.yaml` is the only one applied with `--config-patch-control-plane`.

## IPv6 first, IPv4 for legacy

Both clusters are dual-stack with **IPv6 as the primary family**: `podSubnets` and `serviceSubnets` in `patches/cluster.yaml` list the v6 CIDR first, and Kubernetes derives the default family from that order. A Service without `ipFamilyPolicy` gets a v6 ClusterIP, cluster DNS answers on v6, and node addresses, endpoints, etcd and NTP are v6. IPv4 exists as the fallback: bl3's second nameserver, the default v4 route, masquerade on home (v6 is BGP-routed, never NATed), Hetzner's v4-only DHCP on gw.

## What is a secret here

**Everything that identifies this infrastructure.** Credentials obviously — private keys, passwords, tokens, CAs — but addresses, prefixes, disk serials, interface names and the DNS names too. That the names resolve publicly says how hard they are to find, not whether this repo should hand out the map, and a name is the one thing you need before you can point anything at a host. So no identifier is plaintext: `patches/` is `${VAR}` holes all the way down, and the cluster name and endpoint reach `talosctl gen config` only inside `sops exec-env`.

| Encrypted                                                                                                    | Plaintext                                                                     |
| ------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------- |
| `talenv.sops.yaml` — the DNS names and cluster name, addresses, CIDRs, disks, interfaces, the wg private key | `patches/`, `schematic.yaml` — `${VAR}` holes and structure                   |
| `talsecret.sops.yaml` — cluster CA, etcd keys, bootstrap token                                               |                                                                               |
| `cilium-values.sops.yaml` — the pod CIDRs, and only those                                                    | `cilium.yaml` — the whole HelmRelease: ports, capabilities, MTUs, `0.0.0.0/0` |
| `ippool.sops.yaml` — LB address blocks                                                                       |                                                                               |
| `bgp.sops.yaml` — BGP password, `cluster-secrets`, `*-values` — API keys, restic                             |                                                                               |

### Cilium is deliberately two files

`cilium.yaml` is the manifest and stays plaintext; `cilium-values.sops.yaml` holds the addressing and nothing else. Flux joins them through `valuesFrom`. Encrypting the manifest wholesale — which I tried — makes every Cilium change unreviewable, and putting an `encrypted_regex` on it instead is worse than it looks: see the comment trap below.

The price of two files is one real trap of its own. Both carry an `ipam:` key — `mode` in the manifest, `operator.*` in the values — so **the merge has to be recursive**. A shallow merge drops `mode` and Cilium falls back to the chart default. That is not hypothetical, it shipped, and it would have bitten at the worst possible moment: helm's default happens to match, and flux's `valuesFrom` merge is correct, so `gw` would have bootstrapped fine and then changed IPAM mode the instant flux adopted the release.

So that merge exists exactly once outside flux — `tasks/cilium-values.sh`, called by `<cluster>:cni`.

### Two ways a value still escapes

- **sops only encrypts comments under whole-file rules.** Under an `encrypted_regex` they stay in cleartext, so a comment naming an interface or an address inside a `.sops.yaml` is exactly as public as this file. I wrote one; check 3 caught it.
- **The docs cannot be encrypted at all**, so prose repeating a value is a leak _and_ a second source of truth. Runbooks name the key, never the value: `BL3=$(sops -d talos/home/talenv.sops.yaml | yq -r .BL3_ADDR6)` rather than the address.

`tasks/secrets.sh` enforces all of it, so none of it rests on remembering — and it runs on every commit, from `.githooks/pre-commit`. Install it once per clone with `go-task secrets:hook`; run it by hand with `go-task secrets:check`.

1. everything named `.sops.*` really is encrypted;
2. no credential-shaped literal sits in a plaintext file;
3. no address, interface name or disk id appears in a doc **or in a comment inside an encrypted file**;
4. no doc repeats a string that exists _only_ inside an encrypted file. That one needs no allowlist: if the same string is also in a plaintext config file, the repo publishes it on purpose.
5. the domain, read from the inventory, appears in no unencrypted file at all — docs included. Check 4 exempts anything a plaintext config also carries; this one does not, because after the `${VAR}` move nothing plaintext has a reason to carry a name.

A hook and not CI because checks 4 and 5 compare against decrypted content: without the age key they protect nothing, so the script fails rather than skips when it cannot decrypt. `git commit --no-verify` gets past it.

What this costs: a CIDR change is ciphertext churn in the diff again. sops leaves YAML _keys_ readable, so you still see _which_ variable moved — just not to what. That was the trade, made knowingly.

## Why there is no `gensecret` task

`talsecret.sops.yaml` holds the cluster CA, the etcd keys and the bootstrap token. A cluster CA is created **once in the life of a cluster**. The previous iteration of this repo wrapped it in a task guarded by `test -f`, which is one missed guard away from regenerating the CA and bricking the cluster.

So it is a manual procedure, run once per cluster:

```sh
cd talos/<cluster>
talosctl gen secrets -o /tmp/talsecret.yaml
sops -e --filename-override talos/<cluster>/talsecret.sops.yaml /tmp/talsecret.yaml \
  > talsecret.sops.yaml
shred -u /tmp/talsecret.yaml
```

**Before ever doing this**, add a second age recipient to `.sops.yaml` and run `sops updatekeys` across the repo. Today a single key (`age164zdq…`) decrypts the cluster CA, every `cluster-secrets`, the BGP password, the inventory and the MikroTik exports. Losing it loses all of it.

## Day-2

| Task                                                    | Command                                                                                 |
| ------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| render + validate                                       | `go-task talos:config CLUSTER=home`                                                     |
| secret hygiene                                          | `go-task secrets:check` — and on every commit, once `go-task secrets:hook` is installed |
| boot image / installer URL                              | `go-task talos:url CLUSTER=home`                                                        |
| refresh the schematic ID after editing `schematic.yaml` | `go-task talos:schematic CLUSTER=home`                                                  |
| upgrade Talos                                           | `go-task talos:cmd CLUSTER=home STEP=upgrade`                                           |
| upgrade Kubernetes                                      | `go-task talos:cmd CLUSTER=home STEP=upgrade-k8s`                                       |
| etcd snapshot                                           | `go-task talos:etcd:snapshot CLUSTER=gw`                                                |

`TALOS_VERSION` and `KUBERNETES_VERSION` are pinned in `tasks/talos.yaml` and tracked by a Renovate custom manager.

⚠ **The workstation `talosctl` caps what the render can target.** `talosctl gen config --talos-version` and `validate` come from the installed binary, so keep it at or above `TALOS_VERSION` — a Talos bump PR assumes you upgraded `talosctl` first. Then `go-task talos:config CLUSTER=<c>` for both clusters.

## Bootstrap order

This is the canonical sequence for either cluster. `MIGRATE.md` runs it with the home- and gw-specific detail attached; it does not restate the reasoning.

Three imperative steps exist and cannot be made declarative, plus one bridging secret. Everything else is GitOps.

0. **`go-task talos:config CLUSTER=<c>`**, then `go-task talos:url CLUSTER=<c>`. Nothing downstream exists without this: `apply`, `bootstrap` and `kubeconfig` all read `clusterconfig/`, and the boot artefact URL carries the schematic ID of the extensions this node needs.
1. **Boot the Image Factory artefact** — an ISO for bl3, a dd'd raw image for gw. The node lands in maintenance mode: no config, API on 50000 with no client cert.
2. **`apply-config --insecure`** — `go-task talos:cmd:apply-insecure`. The only unauthenticated step in the cluster's life. ⚠ `-n` must be the **maintenance-mode DHCP address from the console**, not the static address in `talenv.sops.yaml`.
3. Node reboots into `cni: none`. etcd is not up, `talosctl health` hangs. **This is normal.**
4. **`bootstrap`** — `go-task talos:cmd:bootstrap`. **Once. One node. Ever.** Twice, or on a second node, corrupts etcd.
5. **`go-task talos:kubeconfig CLUSTER=<c>`** — writes `~/.kube/clusters/<clusterName>.yaml`, which is the path every `<cluster>:` task expects. The apiserver answers but every pod is `Pending`: no CNI yet. Also normal.
6. **Cilium by helm** — `go-task <cluster>:cni`. Cannot come from flux: flux needs pod networking to run. This is why `k8sServiceHost` is `localhost:7445` (KubePrism) and not a DNS name — at this point there is no CoreDNS and no LB to resolve `KUBE_FQDN`. The task feeds helm the same values flux will compute, via `tasks/cilium-values.sh` — one implementation of that merge, so the handover in step 8 is a no-op.
7. **`go-task <cluster>:flux`.** Creates the `sops-age` secret from `~/.config/sops/age/keys.txt`: the same key that decrypts `talsecret.sops.yaml` locally is what flux uses in-cluster. It cannot come from git — irreducible, and already how the repo works. On home, `go-task home:bgp` first, so the router has a session before flux starts moving addresses around.
8. flux adopts the Cilium release. Because step 6 applied flux's own values, the handover is a no-op — nothing to restart. ⚠ That only holds while there is one source of values. If you ever reintroduce a second one, or hand-edit values on the cluster, restart `cilium-operator` and `cilium-envoy` afterwards or the change is not read.

## Recovery

| Lost                            | Consequence                                                                                                                                     |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `clusterconfig/`, `talosconfig` | nothing. Regenerate.                                                                                                                            |
| `talsecret.sops.yaml`           | cluster unadministrable → rebuild. Back it up off-repo.                                                                                         |
| `gw/talenv.sops.yaml`           | the wg tunnel. Generate a new keypair and update the peer on home-router — the one case where the read-only MikroTik doctrine has to be broken. |
| the age key                     | 🔴 everything: CA, all cluster secrets, inventory, router exports.                                                                              |

Talos CA rotation has no reasonable in-place path — it is a cluster rebuild. Acceptable for a homelab, worth knowing before it matters.

## bl3, as verified on the machine

Read-only over SSH, 2026-08-22. The values that were in `secrets/inventory.sops.yaml` were stale and would not have matched anything.

|              |                                                                                 |
| ------------ | ------------------------------------------------------------------------------- |
| CPU          | Intel N100 (Alder Lake-N) — `siderolabs/i915` + `intel-ucode` confirmed correct |
| GPU          | UHD Graphics, kernel driver `i915`, `/dev/dri/renderD128` present               |
| iface        | one onboard NIC — `BL3_IFACE`                                                   |
| install disk | `nvme0n1`, 477 GB — the by-id path is `BL3_INSTALL_DISK`                        |
| media disk   | `sda`, 3.6 TB, **USB-attached**, xfs, 1.4 TB used, matched by partition label   |

Two corrections that mattered:

- **There is no Crucial MX500 and no `ata-*` link at all on this host.** The disk paths inherited from `secrets/inventory.sops.yaml` were `ata-…` links that do not exist, so the selectors would have matched nothing. That block is now deleted; `talenv` is the only source.
- **There is no separate data disk.** The nvme is the install disk, so `local-path-provisioner` lives on EPHEMERAL (`/var/local-path-provisioner`), not on a user volume.

The 4 TB drive's USB bridge reports a **different serial than the drive itself** — the by-id link and `lsblk` disagree. That is why nothing selects it by path or by serial: it is matched by partition label, see below.

**bl3 has a JetKVM**, which presents itself as a virtual-media device. Virtual media means the install ISO can be mounted remotely: no physical trip, and a console is available if the network config is wrong.

## The 4 TB media disk is adopted, not reformatted

Its partition label is already `u-media-volume` — Talos's own user-volume convention. The disk was provisioned by the _previous_ Talos cluster, survived the k3s era untouched (mounted by the deleted `media.mount`), and still carries the label. So this is re-adopting a Talos volume, not importing a foreign one.

`home/patches/bl3-media-volume.yaml` uses **`ExistingVolumeConfig`**, which discovers and mounts without provisioning:

```yaml
apiVersion: v1alpha1
kind: ExistingVolumeConfig
name: media
discovery:
  volumeSelector:
    match: volume.partition_label == "u-media-volume"
```

It mounts at `/var/mnt/media`, which is what the four media manifests already reference. Removing the document unmounts the volume; Talos does not wipe it. Status shows under an `e-` prefix: `talosctl get volumestatus e-media`.

⚠ **Never turn this into a `UserVolumeConfig`.** That provisions, i.e. partitions and formats. `/media` is covered by **no** `ReplicationSource` — every one of them targets a `*-config` PVC — so the 1.4 TB has no backup. Check by hand after touching this patch: `go-task talos:config CLUSTER=home` then grep the rendered `clusterconfig/bl3.yaml` for `kind: ExistingVolumeConfig`.

## gw is Hetzner Cloud

Platform `hcloud`, set via `machineSpec.mode`. Two axes not to confuse:

- **platform** `hcloud` → selects the `hcloud-amd64` image and the `hcloud-installer`
- **runtime mode** `cloud` → what `validate nodeconfig` checks against (`metal` for bl3)

Hetzner Cloud has no custom-ISO upload, so `machineSpec` asks the factory for a raw disk image (`bootMethod: disk-image`, `imageSuffix: raw.xz`) instead of an ISO. The install is:

1. `go-task talos:url CLUSTER=gw` → the `image` URL is already the `.raw.xz`
2. create a throwaway server, boot the Hetzner Rescue System, `lsblk`
3. `wget -O- <raw.xz> | xz -d | dd of=<disk> bs=4M status=progress`
4. snapshot that server, then rebuild gw from the snapshot

## Open items

- **`GW_ADDR6` is still the old server's address.** It feeds both the static v6 address and every `talosctl -n`, so it must be replaced before the first apply — MIGRATE.md phase 2, step 1.
- **`gw` install disk** — `GW_INSTALL_DISK` holds the Hetzner Cloud default, which is a guess. Confirm with `lsblk` in rescue mode.
- **`gw` has no ingress firewall.** The rules exist, in MIGRATE.md phase 2 step 9, along with the reason not to enable them blind. They are deliberately not a file under `patches/`.
- **`gw`'s public NIC name is still unknown**, which is why `cilium.yaml` matches it as `en+`/`eth+` rather than by name — `--devices` takes `+` wildcards. bl3 confirmed that Talos derives the name from the PCI path, so `eth0` was a bad guess. Worth one `talosctl get links` on the new server anyway.
