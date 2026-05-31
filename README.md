# homelab

A 3-node Kubernetes cluster running on second-hand Lenovo ThinkCentre thin clients.

Everything is GitOps. Everything is declarative. The repo is the cluster — node OS config, networking, storage, observability, auth, and workloads all live here as code and are reconciled automatically. There is no `kubectl apply` step in any normal workflow; a merge to `main` is the deploy.

The stack: [Talos Linux](https://www.talos.dev/) for the OS (immutable, API-driven, no SSH), [Flux](https://fluxcd.io/) for cluster reconciliation, [Cilium](https://cilium.io/) for networking and Gateway API, [Longhorn](https://longhorn.io/) for storage, [cert-manager](https://cert-manager.io/) + Let's Encrypt for TLS, and [Cloudflare](https://www.cloudflare.com/) for public ingress (Tunnel), DNS, and SSO (Access OIDC). Public apps reach the internet via Cloudflare Tunnel; internal apps stay on the LAN behind a wildcard TLS cert; remote access goes through a Tailscale subnet router.

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
| Ad-blocking | Blocky — LAN-wide DNS sinkhole at `192.168.1.202`; pfSense forwards all queries to it |
| Ingress | Cilium Gateway API — internal gateway on LAN, public gateway behind cloudflared |
| Observability | kube-prometheus-stack 85.1.3, Loki 7.0.0 single-binary, Grafana Alloy 1.8.1 DaemonSet, Hubble UI |
| Uptime monitoring | blackbox-exporter probes 8 endpoints; alerts → Discord via Alertmanager `discord_configs` |
| Auth | Cloudflare Access SaaS OIDC → kube-apiserver, Headlamp, and kubectl (via kubelogin) |
| Remote access | Tailscale operator with 2 HA subnet routers advertising `192.168.1.0/24` |
| Dependency updates | Renovate (Mend-hosted) — config in `renovate.json`, opens grouped PRs nightly/weekends |

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
    tailscale/                      Tailscale operator + OAuth secret (installs CRDs)
    tailscale-connectors/           Connector CRs — HA pair of subnet routers (depends on operator)
  security/
    cert-manager/                   cert-manager HelmRelease + Cloudflare token
    cert-manager-issuers/           Let's Encrypt staging + prod ClusterIssuers
  storage/longhorn/                 Longhorn HelmRelease (+ HTTPRoute for UI)
  observability/
    kube-prometheus-stack/          Prometheus + Alertmanager + Grafana (CF Access JWT)
    loki/                           Loki single-binary
    alloy/                          Grafana Alloy DaemonSet (logs → Loki)
    flux-monitoring/                Flux PodMonitor + dashboards (ConfigMaps)
    blackbox-exporter/              Blackbox probes, alert rules, Discord AlertmanagerConfig
    extra-dashboards/               cert-manager / Cilium / Longhorn / Node Exporter / Loki / Blackbox / Blocky dashboards
  system/
    kubelet-csr-approver/           Auto-approves kubelet serving CSRs
    cluster-admin-oidc/             ClusterRoleBinding (SOPS) binding CF Access user → cluster-admin
  apps/                             Workloads (whoami, hello-public, game-2048, headlamp, home-assistant, blocky, ...)
docs/                               Local notes; not deployed
renovate.json                       Renovate config (managed by Mend's hosted GitHub App)
```

Pattern: each subsystem is a directory of raw manifests with a `kustomization.yaml`, paired with a sibling `<name>.yaml` Flux Kustomization wrapper that adds `dependsOn`, SOPS `decryption`, and health checks. The root `clusters/homelab/kustomization.yaml` lists the wrappers.

## Networking

- **Internal apps** live at `*.internal.tylerrosnett.com`. DNS resolves to the LAN gateway IP `192.168.1.200` (L2-announced from one Cilium node). TLS terminated at the gateway using a Let's Encrypt wildcard cert (DNS01).
- **Public apps** live at `<name>.tylerrosnett.com`. DNS is a wildcard CNAME pointing at the Cloudflare tunnel; Cloudflare terminates TLS at its edge and forwards through the tunnel to the in-cluster `cf-tunnel` Gateway over plain HTTP.
- The public gateway gates which namespaces can attach routes by matching the `expose-public: "true"` label on the namespace.
- L2 announcement is opt-in via the `lb-announce: "true"` label on the LoadBalancer Service (set on the internal gateway, not the public one).
- **Redirect-only HTTPRoutes** are possible without any backend Service — see `network/gateway/pfsense-redirect.yaml` for `pfsense.internal.tylerrosnett.com` → 302 to `https://192.168.1.1` via Gateway API's `RequestRedirect` filter.

## Remote access (Tailscale)

The Tailscale operator (`network/tailscale/`) runs in the `tailscale` namespace and is authenticated via an OAuth client (SOPS-encrypted secret `operator-oauth`). Two `Connector` CRs (`network/tailscale-connectors/`) each spawn a subnet-router pod that advertises `192.168.1.0/24` — HA pair: lose one, the other carries traffic.

Operator + CR resources are split into two Flux Kustomizations because the Connector CRDs are installed by the operator's Helm chart; the CRs can't be applied until the CRDs exist. `tailscale-connectors` `dependsOn: tailscale` enforces the ordering.

The `tailscale` namespace carries `pod-security.kubernetes.io/enforce: privileged` — subnet-router pods need privileged containers (sysctls + raw networking).

Split DNS is configured in Tailscale admin (https://login.tailscale.com/admin/dns) → custom nameserver `192.168.1.1` restricted to `internal.tylerrosnett.com`. Clients with `--accept-routes` (Mac/iOS toggle "Use Tailscale Subnets") get LAN access + correct DNS for internal hostnames from anywhere.

Tag `tag:homelab` is auto-applied to managed devices; the corresponding `tagOwners` entry is required in the Tailscale ACL.

## DNS ad-blocking (Blocky)

[Blocky](https://github.com/0xERR0R/blocky) (`apps/blocky/`) is a LAN-wide DNS ad/tracker blocker. pfSense Unbound (`192.168.1.1`) stays the resolver every client talks to and **forwards** all queries to Blocky, which filters against blocklists and forwards clean lookups upstream to Cloudflare over DoT. Clients are untouched (DHCP still hands out pfSense); disabling Unbound's forwarding mode is an instant rollback.

- 2 replicas with pod anti-affinity. DNS is served on a `LoadBalancer` Service at `192.168.1.202` (L2-announced via the `lb-announce` label), ports 53 UDP+TCP, `externalTrafficPolicy: Local`. The HTTP/metrics port is a separate ClusterIP backing a ServiceMonitor.
- Blocklists: StevenBlack + hagezi pro, plus an inline allowlist. Query logging is disabled by choice — only aggregate Prometheus metrics (block rate, query totals, cache hits) are kept, surfaced via Grafana dashboard #13768.
- Namespace PSA is `restricted` (Blocky runs non-root and only needs `NET_BIND_SERVICE` to bind `:53`).

pfSense forwarding-mode gotchas: DNSSEC validation must be **off** (Blocky's synthetic `0.0.0.0` answers for blocked domains fail validation → SERVFAIL on blocked names only), the `private-domain` custom option needs a `server:` prefix to survive forwarding mode, "Use SSL/TLS for outgoing queries" must stay off (Blocky is plain DNS on `:53`), and Blocky must be the sole upstream (forwarding mode races all listed servers). Split-DNS host overrides for `*.internal.tylerrosnett.com` still resolve locally before any forward.

Note: DNS blocking only stops third-party ad/tracker domains — first-party in-app ads (Pinterest, YouTube, Instagram) come down the same domains as the content and aren't blockable this way.

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

## Observability

Stack lives in the `monitoring` namespace.

- **Prometheus** (50Gi Longhorn PVC, 14d retention) — scrapes all PodMonitors/ServiceMonitors cluster-wide (KPS's `*SelectorNilUsesHelmValues: false` flips). Talos overrides: kube-controller-manager `10257`, kube-scheduler `10259`, etcd `2381`, kube-proxy disabled.
- **Alertmanager** (5Gi PVC).
- **Grafana** (5Gi PVC) — only public-facing piece of observability. Exposed at `grafana.tylerrosnett.com` via the `cf-tunnel` Gateway. Auth uses Cloudflare Access JWT (`auth.jwt` against CF's JWKS). Login form disabled; users auto-create as Admin on first JWT login.
- **Loki** single-binary (50Gi PVC, filesystem store).
- **Grafana Alloy** DaemonSet scraping every namespace's pod logs → Loki.
- **Flux dashboards** as ConfigMaps (label `grafana_dashboard: "1"`), PodMonitor for flux-system controllers — see `observability/flux-monitoring/`.

The `monitoring` namespace carries `pod-security.kubernetes.io/enforce: privileged` because node-exporter needs `hostNetwork`/`hostPID`. Grafana uses `Recreate` deployment strategy (RWO PVC + `RollingUpdate` deadlocks).

Internal UIs exposed via `*.internal.tylerrosnett.com`: `longhorn`, `prometheus`, `alertmanager`, `headlamp`, `hubble` (Cilium flow observability — `hubble.relay.enabled` + `hubble.ui.enabled` on the Cilium HelmRelease), `pfsense` (redirect-only).

Prometheus and Alertmanager both have `externalUrl` set to their `*.internal.tylerrosnett.com` hostnames so "Source" links in Alertmanager and links in Discord notifications resolve from a browser (otherwise they'd point at cluster-internal service DNS).

**Extra dashboards** (`observability/extra-dashboards/`): cert-manager, Cilium Agent, Longhorn, Node Exporter Full (grafana.com #1860), Loki, Blackbox Exporter, Blocky (grafana.com #13768). Loaded the same way as Flux dashboards — kustomize `configMapGenerator` with `grafana_dashboard: "1"` label.

## Uptime monitoring and alerts

`observability/blackbox-exporter/`:

- **`prometheus-blackbox-exporter` HelmRelease** with `http_2xx`, `http_2xx_insecure`, and `tcp_connect` probe modules. Exports `probe_success` / `probe_duration_seconds` / `probe_ssl_earliest_cert_expiry` metrics.
- **`Probe` CRDs** (`public-endpoints`, `internal-endpoints`) — 8 URLs scraped every 60s, labeled `category=public|internal`. Edit `probes.yaml` to add/remove targets.
- **`PrometheusRule`** with 4 alerts: `EndpointDown` (probe_success=0 for 3m), `EndpointSlow` (>5s for 10m), `CertExpiringSoon` (<14d), `CertExpired`.
- **`AlertmanagerConfig`** — routes alerts with `severity =~ warning|critical` to a Discord webhook (URL in `secrets/discord-webhook.sops.yaml`). Watchdog and other low-priority alerts are filtered out by the severity matcher.

KPS values include `alertmanagerConfigSelector: { matchLabels: { alertmanagerConfig: discord } }` so Alertmanager picks up the CRD.

## Authentication

The cluster trusts **Cloudflare Access SaaS OIDC** as an identity provider end-to-end. CF Access itself only accepts GitHub OAuth as a login method — email PIN and other IdPs are disabled in Zero Trust settings.

- **kube-apiserver** has `--oidc-issuer-url`, `--oidc-client-id`, `--oidc-username-claim=email` set via a SOPS-encrypted Talos patch (`talos/patches/cluster-apiserver-oidc.sops.yaml`). The Talos rule under `.sops.yaml` for `talos/patches/.*\.sops\.yaml$` decrypts at `talhelper genconfig` time so plaintext stays in gitignored `clusterconfig/`.
- **ClusterRoleBinding** at `clusters/homelab/system/cluster-admin-oidc/secrets/clusterrolebinding.sops.yaml` (SOPS-encrypted) maps the CF Access user email → `cluster-admin`.
- **Headlamp** uses the same SaaS OIDC app via browser flow at `headlamp.internal.tylerrosnett.com/oidc-callback`. Helm values are injected from the encrypted `headlamp-oidc` secret via Flux's `valuesFrom` to work around a chart bug where `secret.create: false` skips OIDC env injection.
- **kubectl** uses [`kubelogin`](https://github.com/int128/kubelogin) against the same SaaS app with redirect `http://localhost:8000`. See "Common operations" below for the kubeconfig wiring.

**CF Access SaaS OIDC quirks** that took a while to debug:
- **PKCE is required**. Both Headlamp (`usePKCE: true`) and kubelogin (`--oidc-pkce-method=S256`) must opt in. CF rejects with `code_challenge is required for this client` otherwise.
- **Refresh tokens require explicit opt-in** on the SaaS app (toggle in OIDC settings). Once enabled, request `offline_access` scope so sessions silently refresh. Without it, clients re-auth on every access-token expiry (~10 min).
- **Group claims need an IdP source** (e.g. GitHub teams). Custom claims on the SaaS app can only map IdP attributes, not literal strings or Rule Groups. Email-based RBAC is the practical fallback for single-user homelabs.

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

# Force kubelogin to re-authenticate (e.g. after CF session expires)
rm -rf ~/.kube/cache/oidc-login/
```

## Notable design choices

- **Cilium installed out-of-band** via Flux HelmRelease (Talos CNI is `none`). kube-proxy is disabled; Cilium's BPF kube-proxy replacement handles it.
- **Install disks selected by size/type** (`installDiskSelector: size: '>= 200GB', type: ssd`), not fixed `/dev/sdX` paths — names aren't stable across reboots when USB media is present.
- **flux-operator + FluxInstance** instead of the classic `flux install`. The FluxInstance is itself reconciled by a Flux HelmRelease for self-management.
- **Two ExternalDNS scopes**: domain filter set to `tylerrosnett.com` (zone discovery requires it), regex filter `^(tylerrosnett\.com|.+\.internal\.tylerrosnett\.com)$` matches both the zone apex (so ExternalDNS can discover the hosted zone) AND the internal records it should manage. The zone apex match is required — without it, ExternalDNS silently skips every record with "no hosted zone matching record DNS Name was detected".
- **Public traffic terminates plaintext inside the cluster** (Cloudflare → cloudflared → public gateway is HTTP). Cilium's identity-aware policy on backend pods uses the `ingress` entity to allow only envoy-originated traffic.
- **Talos kube-controller-manager and kube-scheduler bind to 0.0.0.0** via `patches/cluster-scheduler-controller-bind.yaml`. Default Talos behavior binds them to 127.0.0.1, so Prometheus scrapes via node IP fail. Without the patch you get perpetual `KubeSchedulerInstanceUnreachable` / `KubeControllerManagerInstanceUnreachable` / `TargetDown` alerts.
