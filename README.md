# homelab

GitOps configuration for a 3-node [Talos Linux](https://www.talos.dev/) Kubernetes cluster, reconciled by [Flux](https://fluxcd.io/). Public apps are exposed via Cloudflare Tunnel; internal apps stay on the LAN with their own TLS.

## Cluster

| | |
| --- | --- |
| Nodes | `oak` (192.168.1.5), `maple` (192.168.1.6), `pine` (192.168.1.7) — all control plane |
| API VIP | 192.168.1.246 |
| Talos | v1.13.2 |
| Kubernetes | v1.36.1 |
| CNI | Cilium 1.19.4 (kube-proxy replacement, eBPF, L2 announcements) |
| Storage | Longhorn 1.11.2 (3 replicas, default StorageClass) |
| Certs | cert-manager + Let's Encrypt (DNS01 via Cloudflare) |
| DNS | ExternalDNS → Cloudflare (internal hostnames only) |
| Ingress | Cilium Gateway API — internal gateway on LAN, public gateway behind cloudflared |

## Repository layout

```
talos/                              Talos node config via talhelper (single source of truth)
clusters/homelab/
  flux-system/                      Flux operator + FluxInstance bootstrap
  network/
    gateway-api/                    Gateway API CRDs (pinned)
    cilium/                         Cilium HelmRelease
    cilium-loadbalancer/            IP pool + L2 announcement policy
    gateway/                        Internal + public Gateway resources
    external-dns/                   ExternalDNS HelmRelease + Cloudflare token
    cloudflare-tunnel/              cloudflared Deployment + tunnel token
  security/
    cert-manager/                   cert-manager HelmRelease + Cloudflare token
    cert-manager-issuers/           Let's Encrypt staging + prod ClusterIssuers
  storage/longhorn/                 Longhorn HelmRelease
  system/kubelet-csr-approver/      Auto-approves kubelet serving CSRs
  apps/                             Workloads (whoami, hello-public, game-2048, ...)
docs/                               Local notes; not deployed
```

Pattern: each subsystem is a directory of raw manifests with a `kustomization.yaml`, paired with a sibling `<name>.yaml` Flux Kustomization wrapper that adds `dependsOn`, SOPS `decryption`, and health checks. The root `clusters/homelab/kustomization.yaml` lists the wrappers.

## Networking

- **Internal apps** live at `*.internal.tylerrosnett.com`. DNS resolves to the LAN gateway IP `192.168.1.200` (L2-announced from one Cilium node). TLS terminated at the gateway using a Let's Encrypt wildcard cert (DNS01).
- **Public apps** live at `<name>.tylerrosnett.com`. DNS is a wildcard CNAME pointing at the Cloudflare tunnel; Cloudflare terminates TLS at its edge and forwards through the tunnel to the in-cluster `cf-tunnel` Gateway over plain HTTP.
- The public gateway gates which namespaces can attach routes by matching the `expose-public: "true"` label on the namespace.
- L2 announcement is opt-in via the `lb-announce: "true"` label on the LoadBalancer Service (set on the internal gateway, not the public one).

## Adding a new app

### Internal-only

```
clusters/homelab/apps/<name>/
  namespace.yaml          # plain namespace
  deployment.yaml
  service.yaml
  httproute.yaml          # parentRef: cilium-gateway in kube-system; hostname: <name>.internal.tylerrosnett.com
  kustomization.yaml
```

Then add `<name>` to `clusters/homelab/apps/kustomization.yaml`. ExternalDNS publishes the DNS record automatically.

### Public

```
clusters/homelab/apps/<name>/
  namespace.yaml          # MUST have label expose-public: "true" AND a non-numeric name
  deployment.yaml         # or helmrelease.yaml + repository.yaml
  service.yaml
  httproute.yaml          # parentRef: cf-tunnel in kube-system; hostname: <name>.tylerrosnett.com
  networkpolicy.yaml      # CiliumNetworkPolicy allowing fromEntities [ingress, host, remote-node]
  kustomization.yaml
```

Then add `<name>` to `clusters/homelab/apps/kustomization.yaml`. The wildcard `*.tylerrosnett.com` CNAME points at the tunnel, so no DNS work is needed per app.

Important: don't use multi-level hostnames for public apps (Cloudflare's free Universal SSL only covers one wildcard level).

## Secrets

Encrypted with [sops](https://github.com/getsops/sops) + age. Files matching `clusters/.*/secrets/.*\.yaml` are auto-encrypted by the `.sops.yaml` rules. The age private key lives outside the repo.

To edit an existing secret:

```bash
sops clusters/homelab/<path>/secrets/<file>.sops.yaml
```

To create a new one, write the plaintext Secret at its destination, then `sops -e -i <file>`.

## Common operations

```bash
# Regenerate Talos configs (in talos/)
talhelper genconfig

# Apply Talos config to a node
talosctl apply-config --insecure --nodes <ip> --file ./clusterconfig/<hostname>.yaml

# Get kubeconfig
talosctl kubeconfig --nodes 192.168.1.246 --endpoints 192.168.1.246

# Force a Flux reconcile
flux reconcile kustomization flux-system --with-source

# See sync state
flux get kustomizations
flux get helmreleases -A
```

## Notable design choices

- **Cilium installed out-of-band** via Flux HelmRelease (Talos CNI is `none`). kube-proxy is disabled; Cilium's BPF kube-proxy replacement handles it.
- **Install disks selected by size/type** (`installDiskSelector: size: '>= 200GB', type: ssd`), not fixed `/dev/sdX` paths — names aren't stable across reboots when USB media is present.
- **flux-operator + FluxInstance** instead of the classic `flux install`. The FluxInstance is itself reconciled by a Flux HelmRelease for self-management.
- **Two ExternalDNS scopes**: domain filter set to `tylerrosnett.com` (zone discovery requires it), regex filter restricts ownership to `.+\.internal\.tylerrosnett\.com$` so the tunnel's public CNAMEs aren't touched.
- **Public traffic terminates plaintext inside the cluster** (Cloudflare → cloudflared → public gateway is HTTP). Cilium's identity-aware policy on backend pods uses the `ingress` entity to allow only envoy-originated traffic.
