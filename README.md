# homelab

A Talos Kubernetes cluster on three Lenovo ThinkCentre Tiny PCs, plus a gaming desktop that joins as a part-time GPU node.

## Stack

| Area | Choice |
| --- | --- |
| OS | [Talos Linux](https://www.talos.dev/), configured with `talosctl` (`talos/README.md`) |
| GitOps | [Flux](https://fluxcd.io/) via flux-operator |
| Network | [Cilium](https://cilium.io/): CNI, kube-proxy replacement, L2 announcements, Gateway API |
| Storage | [Longhorn](https://longhorn.io/); [Garage](https://garagehq.deuxfleurs.fr/) for S3 |
| TLS and DNS | cert-manager + Let's Encrypt; ExternalDNS → Cloudflare |
| Ingress | Internal gateway on the LAN; public apps through Cloudflare Tunnel |
| Auth | Cloudflare Access OIDC |
| Remote access | Tailscale subnet routers |
| Observability | kube-prometheus-stack, Loki, Alloy, blackbox-exporter |
| Policy | Kyverno |
| Secrets | SOPS + age |
| Updates | Renovate, merged manually |

## Nodes

| Node | Role | Address |
| --- | --- | --- |
| `oak`, `maple`, `pine` | Control plane, schedulable | 10.10.10.5, .6, .7 |
| `willow` | GPU worker (RTX 3080), dual-boots | 10.10.10.8 |
| API VIP | | 10.10.10.246 |

Versions: `talos/versions.env`.

## Local inference

```
client → Cilium Gateway → agentgateway → InferencePool (llm-d-router) → vLLM on willow
```

- **GPU:** NVIDIA GPU Operator + DRA driver
- **Models:** [ModelPack](https://modelpack.org/) artifacts built from `models/`, mounted by the ModelPack CSI driver, pulled through [Dragonfly](https://d7y.io/)
- **Endpoints:** `llm.internal.tylerrosnett.com` (LAN), Open WebUI at `llm.tylerrosnett.com` (Cloudflare Access)

## Layout

```
talos/                  Node config, schematics, render scripts
models/                 Model specs
clusters/homelab/
  flux-system/          Flux bootstrap
  network/              Cilium, gateways, ExternalDNS, cloudflared, Tailscale, agentgateway
  security/             cert-manager, Kyverno
  storage/              Longhorn, Garage
  observability/        Prometheus stack, Loki, Alloy, dashboards, uptime probes
  gpu/                  GPU Operator, DRA driver
  dragonfly/            Dragonfly scheduler, dfdaemon
  model-csi/            ModelPack CSI driver
  inference/            vLLM, InferencePool, inference gateway
  system/               kubelet CSR approver, admin RBAC
  apps/                 Workloads
```

Each directory has a sibling `<name>.yaml` Flux Kustomization, listed in `clusters/homelab/kustomization.yaml`.

## Adding an app

Internal (`<name>.internal.tylerrosnett.com`):
- Namespace, Deployment, Service
- HTTPRoute on `cilium-gateway`

Public (`<name>.tylerrosnett.com`, one level deep):
- Namespace labeled `expose-public: "true"`
- Deployment, Service
- HTTPRoute on `cf-tunnel`
- CiliumNetworkPolicy allowing `ingress`, `host`, `remote-node`

Add the app to `clusters/homelab/apps/kustomization.yaml`.

## Secrets

SOPS + age, under `clusters/*/secrets/`:

```bash
sops clusters/homelab/<path>/secrets/<file>.sops.yaml
```

## Commands

```bash
cd talos && ./genconfig.sh && ./dryrun.sh <node> <ip>
talosctl kubeconfig -n 10.10.10.246 -e 10.10.10.246
flux get kustomizations
flux reconcile kustomization flux-system --with-source
```
