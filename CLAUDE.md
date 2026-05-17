# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

GitOps configuration for a 3-node Talos Linux Kubernetes homelab. The repo is in an early bootstrap phase — most directories are scaffolding (`.gitkeep`) waiting for content. The intended layout (Flux-style):

- `talos/` — Talos node configuration via [talhelper](https://github.com/budimanjojo/talhelper); `talconfig.yaml` is the single source of truth.
- `clusters/homelab/flux-system/` — Flux bootstrap and root Kustomizations for the `homelab` cluster.
- `infrastructure/` — cluster-level controllers (CNI, ingress, storage, secrets) managed by Flux.
- `apps/homelab/` — workload manifests reconciled by Flux.
- `sandbox/argocd/` — placeholder for an Argo CD experiment alongside Flux.
- `docs/` — local notes (e.g. `docs/superpowers/plans/`); not deployed.

## Cluster facts (don't re-derive)

- Nodes: `oak` 192.168.1.5, `maple` 192.168.1.6, `pine` 192.168.1.7 — all controlplane.
- Kubernetes API VIP: `192.168.1.246` (Talos shared VIP on eth0).
- Talos `v1.13.2`, Kubernetes `v1.36.1`.
- CNI is `none` in Talos config — **Cilium is installed out-of-band**, so any networking work must account for Cilium being the actual CNI.
- `kube-proxy` is disabled (Cilium kube-proxy replacement expected).
- Install disk on every node is selected by `installDiskSelector` (`size: '>= 200GB', type: ssd`) rather than a fixed `/dev/sdX` path — block device names aren't stable across reboots when USB media is present. System extensions enabled: `iscsi-tools`, `util-linux-tools`.
- Kubelet uses `rotate-server-certificates: true`.

## Common commands

Talos config workflow (run from `talos/`):

```bash
talhelper genconfig                                                # regenerate ./clusterconfig/ (gitignored)
talosctl disks --insecure --nodes <node-ip>                        # confirm disk name before apply
talosctl apply-config --insecure --nodes <ip> --file ./clusterconfig/<hostname>.yaml
talosctl bootstrap --nodes 192.168.1.5                             # ONCE, after all 3 nodes are up
talosctl kubeconfig --nodes 192.168.1.246 --endpoints 192.168.1.246
```

Secrets:

```bash
talhelper gensecret > talsecret.sops.yaml && sops -e -i talsecret.sops.yaml   # first time only
sops <file>                                                                   # edit any SOPS-encrypted file
```

## SOPS / secrets

- Encryption is **age** with recipient `age1seegwzyg0ldnm2jerlpsyzkcrqctytqthwdpf0h9fs20w4nngqlqsvpaa0` (see `.sops.yaml`).
- Auto-encrypted paths: `talos/talsecret.sops.yaml` and anything matching `infrastructure/.*/secrets/.*\.yaml`. When creating new secret files, place them under one of these paths so `.sops.yaml` rules apply automatically — otherwise they'll be committed in plaintext.
- The private key lives outside the repo; `*.agekey` and `.secrets` are gitignored.
- `talos/clusterconfig/` is gitignored — never commit generated per-node configs.

## Conventions

- Single source of truth for node config is `talos/talconfig.yaml` + `talos/patches/*.yaml`. Don't hand-edit generated configs under `clusterconfig/`; change the source and regenerate.
- Patches in `talos/patches/` are referenced from `talconfig.yaml` via `@./patches/...` — keep them small and single-purpose (see existing `cluster-cni-none`, `cluster-proxy-disabled`, `machine-kubelet`, `machine-time`).
- NTP is pinned to `time.cloudflare.com`.
