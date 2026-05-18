# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

GitOps configuration for a 3-node Talos Linux Kubernetes homelab. Flat layout — everything cluster-related lives under `clusters/homelab/` (single cluster, no need to split apps from infra across directories):

- `talos/` — Talos node configuration via [talhelper](https://github.com/budimanjojo/talhelper); `talconfig.yaml` is the single source of truth.
- `clusters/homelab/flux-system/` — Flux bootstrap (flux-operator + FluxInstance) and root Kustomizations for the `homelab` cluster.
- `clusters/homelab/network/` — CNI (Cilium), Gateway API CRDs, LB IP pool / L2 announce, Gateways (internal `*.ik8s` + public `*.k8s` for Cloudflare Tunnel), ExternalDNS, cloudflared.
- `clusters/homelab/security/` — cert-manager + ClusterIssuers.
- `clusters/homelab/storage/` — Longhorn.
- `clusters/homelab/system/` — cluster-level helpers (e.g. kubelet-csr-approver).
- `clusters/homelab/apps/` — workload manifests (deployments, services, HTTPRoutes, NetworkPolicies).
- `docs/` — local notes (e.g. `docs/superpowers/plans/`); not deployed.

Each subsystem follows the pattern: a directory with raw manifests + `kustomization.yaml`, and a sibling `<name>.yaml` Flux Kustomization wrapper that adds `dependsOn`, `decryption`, and `healthChecks`. The root `clusters/homelab/kustomization.yaml` lists those wrappers.

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
- Auto-encrypted paths: `talos/talsecret.sops.yaml` and anything matching `clusters/.*/secrets/.*\.yaml`. When creating new secret files, place them under one of these paths so `.sops.yaml` rules apply automatically — otherwise they'll be committed in plaintext.
- The private key lives outside the repo; `*.agekey` and `.secrets` are gitignored.
- `talos/clusterconfig/` is gitignored — never commit generated per-node configs.

## Conventions

- Single source of truth for node config is `talos/talconfig.yaml` + `talos/patches/*.yaml`. Don't hand-edit generated configs under `clusterconfig/`; change the source and regenerate.
- Patches in `talos/patches/` are referenced from `talconfig.yaml` via `@./patches/...` — keep them small and single-purpose (see existing `cluster-cni-none`, `cluster-proxy-disabled`, `machine-kubelet`, `machine-time`).
- NTP is pinned to `time.cloudflare.com`.

## Gateway pattern (adding new apps)

Two Cilium Gateways are wired up:

- **Internal** — `cilium-gateway` in `kube-system`. Listens on `*.internal.tylerrosnett.com` (HTTP + HTTPS). LoadBalancer service with L2-announced LAN IP `192.168.1.200`. TLS terminated at the gateway using a Let's Encrypt wildcard cert (via cert-manager DNS01). LAN-only.
- **Public** — `cf-tunnel` in `kube-system`. Listens on `*.tylerrosnett.com` (HTTP). LoadBalancer service with LB IP `192.168.1.201` (not announced on LAN — see L2 scoping below). cloudflared connects to it via cluster DNS and exposes it through Cloudflare's edge with their cert. Public-internet-facing.

### Adding an internal-only app

App namespace doesn't need any special label. Create:
- `Namespace`
- `Deployment` + `Service`
- `HTTPRoute` with `parentRefs: [{ name: cilium-gateway, namespace: kube-system }]` and `hostnames: [<name>.internal.tylerrosnett.com]`

ExternalDNS auto-publishes `<name>.internal.tylerrosnett.com → 192.168.1.200` to Cloudflare DNS (regex-scoped to `.internal.`). TLS via the existing wildcard cert.

### Adding a public-internet app

- `Namespace` **must carry label `expose-public: "true"`** (gates `cf-tunnel`'s `allowedRoutes` selector)
- `Deployment` + `Service`
- `HTTPRoute` with `parentRefs: [{ name: cf-tunnel, namespace: kube-system }]` and `hostnames: [<name>.tylerrosnett.com]`
- **`CiliumNetworkPolicy`** on the backend pods allowing ingress from `fromEntities: [ingress, host, remote-node]` (standard `NetworkPolicy` with `ipBlock` does NOT match Cilium's envoy-on-hostNetwork traffic — must use CNP). Reference template: `apps/hello-public/networkpolicy.yaml`.

DNS for public apps relies on the wildcard CNAME `*.tylerrosnett.com → <tunnel-id>.cfargotunnel.com` in Cloudflare. New apps need no DNS work. Cloudflare's Universal SSL covers `*.tylerrosnett.com` (one level), so don't use multi-level names like `<name>.something.tylerrosnett.com` for public apps — those won't have valid certs.

### L2 announcement scoping

`CiliumL2AnnouncementPolicy/default-l2-policy` has `serviceSelector: { lb-announce: "true" }`. Only services with that label get their LB IP announced on the LAN. The internal gateway sets it via `spec.infrastructure.labels` on the Gateway. Don't label services you don't want LAN-reachable.
