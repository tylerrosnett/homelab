# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

GitOps configuration for a 3-node Talos Linux Kubernetes homelab. Flat layout — everything cluster-related lives under `clusters/homelab/` (single cluster, no need to split apps from infra across directories):

- `talos/` — Talos node configuration via [talhelper](https://github.com/budimanjojo/talhelper); `talconfig.yaml` is the single source of truth.
- `clusters/homelab/flux-system/` — Flux bootstrap (flux-operator + FluxInstance) and root Kustomizations for the `homelab` cluster.
- `clusters/homelab/network/` — CNI (Cilium), Gateway API CRDs, LB IP pool / L2 announce, Gateways (internal `*.ik8s` + public `*.k8s` for Cloudflare Tunnel), ExternalDNS, cloudflared.
- `clusters/homelab/security/` — cert-manager + ClusterIssuers.
- `clusters/homelab/storage/` — Longhorn (+ HTTPRoute exposing the UI internally).
- `clusters/homelab/observability/` — kube-prometheus-stack (Prometheus, Alertmanager, Grafana), Loki single-binary, Grafana Alloy DaemonSet, Flux PodMonitor + dashboards.
- `clusters/homelab/system/` — cluster-level helpers (`kubelet-csr-approver`, `cluster-admin-oidc` for the SOPS-encrypted OIDC ClusterRoleBinding).
- `clusters/homelab/apps/` — workload manifests (deployments, services, HTTPRoutes, NetworkPolicies). Includes `headlamp` (cluster-admin dashboard with CF Access OIDC).
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
- Auto-encrypted paths: `talos/talsecret.sops.yaml`, `talos/patches/*.sops.yaml` (encrypted Talos patches — talhelper auto-decrypts on `genconfig`), and anything matching `clusters/.*/secrets/.*\.yaml`. When creating new secret files, place them under one of these paths so `.sops.yaml` rules apply automatically — otherwise they'll be committed in plaintext.
- Non-Secret resources can also be SOPS-encrypted (e.g. the ClusterRoleBinding at `system/cluster-admin-oidc/secrets/clusterrolebinding.sops.yaml` keeps the admin email out of plaintext git). Flux's KS-level `decryption: sops` patch (in `flux-system/flux-instance.yaml`) decrypts any kind, not just `Secret`.
- The private key lives outside the repo; `*.agekey` and `.secrets` are gitignored.
- `talos/clusterconfig/` is gitignored — never commit generated per-node configs.

## Conventions

- Single source of truth for node config is `talos/talconfig.yaml` + `talos/patches/*.yaml`. Don't hand-edit generated configs under `clusterconfig/`; change the source and regenerate.
- Patches in `talos/patches/` are referenced from `talconfig.yaml` via `@./patches/...` — keep them small and single-purpose (see existing `cluster-cni-none`, `cluster-proxy-disabled`, `machine-kubelet`, `machine-time`). Sensitive patches use the `.sops.yaml` suffix (e.g. `cluster-apiserver-oidc.sops.yaml`) so talhelper decrypts them at config-gen time and the plaintext only lands in gitignored `clusterconfig/`.
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

ExternalDNS auto-publishes `<name>.internal.tylerrosnett.com → 192.168.1.200` to Cloudflare DNS (regex `^(tylerrosnett\.com|.+\.internal\.tylerrosnett\.com)$` — apex match is required for zone discovery, even though only `*.internal.*` records get managed). TLS via the existing wildcard cert.

Optional polish: add a **Bookmark application** in Cloudflare Zero Trust (Access → Applications → Add → Bookmark) pointing at the new internal hostname so it shows up in the App Launcher (`https://tylerrosnett.cloudflareaccess.com/`). Bookmarks don't gate the destination (it's still LAN-only), just provide a directory.

### Adding a public-internet app

- `Namespace` **must carry label `expose-public: "true"`** (gates `cf-tunnel`'s `allowedRoutes` selector)
- `Deployment` + `Service`
- `HTTPRoute` with `parentRefs: [{ name: cf-tunnel, namespace: kube-system }]` and `hostnames: [<name>.tylerrosnett.com]`
- **`CiliumNetworkPolicy`** on the backend pods allowing ingress from `fromEntities: [ingress, host, remote-node]` (standard `NetworkPolicy` with `ipBlock` does NOT match Cilium's envoy-on-hostNetwork traffic — must use CNP). Reference template: `apps/hello-public/networkpolicy.yaml`.

DNS for public apps relies on the wildcard CNAME `*.tylerrosnett.com → <tunnel-id>.cfargotunnel.com` in Cloudflare. New apps need no DNS work. Cloudflare's Universal SSL covers `*.tylerrosnett.com` (one level), so don't use multi-level names like `<name>.something.tylerrosnett.com` for public apps — those won't have valid certs.

### L2 announcement scoping

`CiliumL2AnnouncementPolicy/default-l2-policy` has `serviceSelector: { lb-announce: "true" }`. Only services with that label get their LB IP announced on the LAN. The internal gateway sets it via `spec.infrastructure.labels` on the Gateway. Don't label services you don't want LAN-reachable.

## Observability conventions

- Everything lives in `monitoring` namespace.
- The namespace **must** carry `pod-security.kubernetes.io/enforce: privileged` — node-exporter needs `hostNetwork`/`hostPID` and PSA `restricted` will silently block its DaemonSet pods from scheduling (no pods created at all). Same pattern as `longhorn-system`.
- KPS HelmRelease has Talos-specific port overrides for kube-controller-manager (`10257`), kube-scheduler (`10259`), kube-etcd (`2381`), and `kubeProxy.enabled: false` (kube-proxy is disabled in this cluster). Don't forget these when bumping KPS or troubleshooting broken ServiceMonitor targets.
- Prometheus selector flips: `podMonitorSelectorNilUsesHelmValues: false` etc — so all PodMonitors/ServiceMonitors cluster-wide get picked up regardless of the `release` label. Required for Flux's PodMonitor in `flux-system` to be scraped.
- Grafana uses `deploymentStrategy: { type: Recreate, rollingUpdate: null }`. With a RWO Longhorn PVC, the default `RollingUpdate` deadlocks (new pod waits forever for PVC). Explicitly setting `rollingUpdate: null` is required because Helm's deep-merge otherwise keeps the chart's default `maxSurge`/`maxUnavailable`, which the K8s API rejects when `type: Recreate`.
- Dashboards are loaded via Grafana's sidecar by labeling ConfigMaps `grafana_dashboard: "1"` (KPS values set `sidecar.dashboards.searchNamespace: ALL` so the sidecar discovers from any namespace).

## OIDC auth (Cloudflare Access SaaS)

The cluster trusts a single Cloudflare Access SaaS OIDC application for all interactive auth. **Only GitHub OAuth is enabled as a CF Access login method** (email PIN and all other IdPs disabled in Zero Trust → Settings → Authentication). This means anyone reaching cluster auth must have a GitHub account permitted by the CF Access Rule Group.

- **kube-apiserver** validates id_tokens via `--oidc-issuer-url`, `--oidc-client-id`, `--oidc-username-claim=email` (set in `talos/patches/cluster-apiserver-oidc.sops.yaml`, SOPS-encrypted).
- **ClusterRoleBinding** at `clusters/homelab/system/cluster-admin-oidc/secrets/clusterrolebinding.sops.yaml` (SOPS-encrypted) maps the user email → `cluster-admin`.
- **Headlamp** (`apps/headlamp/`) uses the same SaaS app via browser flow. Helm values inject OIDC creds from the SOPS secret via Flux's `spec.valuesFrom` (not `secret.create: false`, which hits a chart bug that skips OIDC env injection).
- **kubectl** uses `kubelogin` against the same app with `http://localhost:8000` as an additional redirect URL on the SaaS app.

**CF Access SaaS OIDC gotchas** (don't re-derive these):
- **PKCE is required** by CF for SaaS apps. Headlamp values must set `config.oidc.usePKCE: true`; kubelogin must pass `--oidc-pkce-method=S256`. Without it CF rejects with `code_challenge is required for this client`.
- **Refresh tokens require explicit opt-in** on the CF Access SaaS app (toggle in the app's OIDC settings). Once enabled, request `offline_access` scope from clients (Headlamp `scopes: ... offline_access`, kubelogin `--oidc-extra-scope=offline_access`). With it on, sessions silently refresh; without it, you re-auth at every access-token expiry (~10 min default).
- **Custom claims on SaaS apps can only map IdP attributes**, not literal strings or Rule Group references. So you can't synthesize a `groups` claim with `homelab-admins` from CF alone — needs to come from a GitHub team or Google Workspace group. For single-user homelab, just bind by email and SOPS-encrypt the CRB.
- **Identity endpoint** for debugging claims: `https://tylerrosnett.cloudflareaccess.com/cdn-cgi/access/get-identity` (after logging in to any CF Access app). Returns session-level claims as JSON. Force re-auth via `https://tylerrosnett.cloudflareaccess.com/cdn-cgi/access/logout`.

When adding a new app that should be behind CF Access (rather than just LAN-only), prefer reusing the existing SaaS app's client ID by adding a new redirect URL, or create a new SaaS app if isolation matters. Either way: PKCE on, no `offline_access`, JWT scope `openid email profile groups`.
