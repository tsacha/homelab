# Talos

The `home` and `gw` clusters use the same layout:

```
talos/<cluster>/
  talenv.sops.yaml      inventory and networking
  talsecret.sops.yaml   cluster root of trust
  schematic.yaml        Image Factory customization
  schematic.id          Image Factory schematic ID
  patches/              machine configuration patches
  clusterconfig/        generated and ignored
```

`go-task talos:config CLUSTER=<home|gw>` renders and validates the machine
configuration. It decrypts SOPS data only for the render, expands the
variables used in `patches/`, and writes the result to `clusterconfig/`.

## Operations

| Operation           | Command                                                 |
| ------------------- | ------------------------------------------------------- |
| Render and validate | `go-task talos:config CLUSTER=home`                     |
| Render then apply   | `go-task talos:apply CLUSTER=home`                      |
| Any Talos command   | `go-task talos:ctl CLUSTER=home -- <talosctl-command>` |
| Secret checks       | `go-task secrets:check`                                 |

The bootstrap path is: render, boot the Image Factory image, apply the initial
config in maintenance mode, bootstrap etcd once, fetch the kubeconfig, install
Cilium, then bootstrap Flux. Cilium is installed imperatively only to provide
networking for Flux; afterwards Flux owns it.

## Secrets and storage

`talsecret.sops.yaml` is created once for each cluster and must be backed up
outside this repository. Regenerating it for an existing cluster changes its
root of trust.

Cilium values are split between its HelmRelease and
`cilium-values.sops.yaml`. The bootstrap task uses `tasks/cilium-values.sh` to
merge them recursively; a shallow merge loses `ipam.mode`.

`home/patches/bl3-media-volume.yaml` adopts the existing media volume. Do not
replace it with `UserVolumeConfig`, which provisions and formats a volume.
