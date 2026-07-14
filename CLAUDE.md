# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

GitOps configuration for a 3-node Talos Linux Kubernetes homelab. Flat layout — everything cluster-related lives under `clusters/homelab/` (single cluster, no need to split apps from infra across directories):

- `talos/` — Talos node configuration via [talhelper](https://github.com/budimanjojo/talhelper); `talconfig.yaml` is the single source of truth.
- `clusters/homelab/flux-system/` — Flux bootstrap (flux-operator + FluxInstance) and root Kustomizations for the `homelab` cluster.
- `clusters/homelab/network/` — CNI (Cilium), Gateway API CRDs, LB IP pool / L2 announce, Gateways (internal `*.ik8s` + public `*.k8s` for Cloudflare Tunnel), ExternalDNS, cloudflared, Tailscale operator + subnet-router Connectors.
- `clusters/homelab/security/` — cert-manager + ClusterIssuers.
- `clusters/homelab/storage/` — Longhorn (+ HTTPRoute exposing the UI internally).
- `clusters/homelab/observability/` — kube-prometheus-stack (Prometheus, Alertmanager, Grafana), Loki single-binary, Grafana Alloy DaemonSet, Flux PodMonitor + dashboards, blackbox-exporter (uptime probes + Discord alerts), extra-dashboards (cert-manager / Cilium / Longhorn / Node Exporter Full / Loki / Blackbox / Blocky / Energy JSONs as ConfigMaps).
- `clusters/homelab/system/` — cluster-level helpers (`kubelet-csr-approver`, `cluster-admin-oidc` for the SOPS-encrypted OIDC ClusterRoleBinding).
- `clusters/homelab/apps/` — workload manifests (deployments, services, HTTPRoutes, NetworkPolicies). Includes `headlamp` (cluster-admin dashboard with CF Access OIDC) and `home-assistant` (smart-home hub + smart-plug energy metrics source).
- `docs/` — local notes (e.g. `docs/superpowers/plans/`); not deployed.
- `renovate.json` — config for the Mend-hosted Renovate GitHub App. Detects HelmRelease chart versions, OCI/HTTPS HelmRepositories, kustomize images, GHA digests, plus custom regex managers for `talosVersion:` and `kubernetesVersion:` in `talconfig.yaml`. Opens PRs only after 6pm + weekends to avoid daytime noise. Renovate maintains a "Dependency Dashboard" issue tracking everything it finds.

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

**Never combine L2 announce with `externalTrafficPolicy: Local`.** Cilium's per-service lease election (`kubectl -n kube-system get lease | grep l2announce`) ignores pod placement, so a node with no local backend can win the lease, answer ARP, and blackhole all traffic. Symptom: pods Ready + endpoints populated but the LB IP times out from the LAN. Fix: delete the lease to force re-election; durable fix: use default `Cluster` policy. When retesting from a client, flush its ARP cache first (`sudo arp -d <ip>`) — a stale entry pointing at the old holder fakes continued failure after the lease moves.

## Observability conventions

- Everything lives in `monitoring` namespace.
- The namespace **must** carry `pod-security.kubernetes.io/enforce: privileged` — node-exporter needs `hostNetwork`/`hostPID` and PSA `restricted` will silently block its DaemonSet pods from scheduling (no pods created at all). Same pattern as `longhorn-system`.
- KPS HelmRelease has Talos-specific port overrides for kube-controller-manager (`10257`), kube-scheduler (`10259`), kube-etcd (`2381`), and `kubeProxy.enabled: false` (kube-proxy is disabled in this cluster). Don't forget these when bumping KPS or troubleshooting broken ServiceMonitor targets.
- Prometheus selector flips: `podMonitorSelectorNilUsesHelmValues: false` etc — so all PodMonitors/ServiceMonitors cluster-wide get picked up regardless of the `release` label. Required for Flux's PodMonitor in `flux-system` to be scraped.
- Grafana uses `deploymentStrategy: { type: Recreate, rollingUpdate: null }`. With a RWO Longhorn PVC, the default `RollingUpdate` deadlocks (new pod waits forever for PVC). Explicitly setting `rollingUpdate: null` is required because Helm's deep-merge otherwise keeps the chart's default `maxSurge`/`maxUnavailable`, which the K8s API rejects when `type: Recreate`.
- Dashboards are loaded via Grafana's sidecar by labeling ConfigMaps `grafana_dashboard: "1"` (KPS values set `sidecar.dashboards.searchNamespace: ALL` so the sidecar discovers from any namespace).
- **Sidecar-provisioned dashboard JSONs must define a `DS_PROMETHEUS` datasource template variable** in `templating.list` (`type: datasource, query: prometheus, hide: 2`). Provisioning does NOT substitute the `__inputs` block, so panels referencing `${DS_PROMETHEUS}` without the variable fail with "datasource not found" on every panel. See any existing JSON in `extra-dashboards/dashboards/` for the pattern.
- **Talos kube-controller-manager + kube-scheduler must bind on 0.0.0.0** for Prometheus to scrape them. Default Talos binds to 127.0.0.1 only. Fix lives at `talos/patches/cluster-scheduler-controller-bind.yaml`. Symptom of missing this: perpetual `KubeSchedulerInstanceUnreachable` / `KubeControllerManagerInstanceUnreachable` / `TargetDown` alerts even with KPS's port overrides set.
- **Prometheus + Alertmanager `externalUrl`** are set to `https://{prometheus,alertmanager}.internal.tylerrosnett.com`. Without these, "Source" links in Alertmanager UI and `generatorURL` in alert payloads default to in-cluster service DNS (`kube-prometheus-stack-prometheus.monitoring:9090`) which doesn't resolve outside the cluster.
- **Longhorn manager restart-count cleanup is dangerous.** Deleting a `longhorn-manager` pod triggers an optimistic-concurrency race on Setting CR updates at startup (`Operation cannot be fulfilled on settings.longhorn.io "default-replica-count"`), which keeps fatal-exiting until contention settles. Symptom is a pod that keeps restarting after a clean delete. Resolution is to leave it alone or delete all longhorn-managers + driver-deployer together so they re-elect cleanly. Don't try to zero out their restart counts.

## OIDC auth (Cloudflare Access SaaS)

The cluster trusts a single Cloudflare Access SaaS OIDC application for all interactive auth. **Only GitHub OAuth is enabled as a CF Access login method** (email PIN and all other IdPs disabled in Zero Trust → Settings → Authentication). This means anyone reaching cluster auth must have a GitHub account permitted by the CF Access Rule Group.

- **kube-apiserver** validates id_tokens via `--oidc-issuer-url`, `--oidc-client-id`, `--oidc-username-claim=email` (set in `talos/patches/cluster-apiserver-oidc.sops.yaml`, SOPS-encrypted).
- **ClusterRoleBinding** at `clusters/homelab/system/cluster-admin-oidc/secrets/clusterrolebinding.sops.yaml` (SOPS-encrypted) maps the user email → `cluster-admin`.
- **Headlamp** (`apps/headlamp/`) uses the same SaaS app via browser flow. Helm values inject OIDC creds from the SOPS secret via Flux's `spec.valuesFrom` (not `secret.create: false`, which hits a chart bug that skips OIDC env injection).
- **kubectl** uses `kubelogin` against the same app with `http://localhost:8000` as an additional redirect URL on the SaaS app. The SaaS app has **Allow PKCE without Client Secret** enabled, so kubectl runs as a public client and needs no client secret (Headlamp still passes its secret; that toggle only *also* permits secret-less PKCE requests).

**CF Access SaaS OIDC gotchas** (don't re-derive these):
- **PKCE is required** by CF for SaaS apps. Headlamp values must set `config.oidc.usePKCE: true`; kubelogin must pass `--oidc-pkce-method=S256`. Without it CF rejects with `code_challenge is required for this client`.
- **Refresh tokens require explicit opt-in** on the CF Access SaaS app (toggle in the app's OIDC settings). Once enabled, request `offline_access` scope from clients (Headlamp `scopes: ... offline_access`, kubelogin `--oidc-extra-scope=offline_access`). With it on, sessions silently refresh; without it, you re-auth at every access-token expiry (~10 min default).
- **Custom claims on SaaS apps can only map IdP attributes**, not literal strings or Rule Group references. So you can't synthesize a `groups` claim with `homelab-admins` from CF alone — needs to come from a GitHub team or Google Workspace group. For single-user homelab, just bind by email and SOPS-encrypt the CRB.
- **Identity endpoint** for debugging claims: `https://tylerrosnett.cloudflareaccess.com/cdn-cgi/access/get-identity` (after logging in to any CF Access app). Returns session-level claims as JSON. Force re-auth via `https://tylerrosnett.cloudflareaccess.com/cdn-cgi/access/logout`.

When adding a new app that should be behind CF Access (rather than just LAN-only), prefer reusing the existing SaaS app's client ID by adding a new redirect URL, or create a new SaaS app if isolation matters. Either way: PKCE on, JWT scope `openid email profile groups offline_access` (refresh tokens are enabled on the existing SaaS app).

## Tailscale subnet router

`network/tailscale/` (operator + CRD install) and `network/tailscale-connectors/` (Connector CRs) are split into two Flux Kustomizations because the Connector CRD is installed by the operator's chart — CRs can't be reconciled before the CRD exists. `tailscale-connectors` has `dependsOn: tailscale`.

- OAuth client (Tailscale admin) provides the `operator-oauth` secret. The Helm chart's `oauth.clientId`/`oauth.clientSecret` are left empty in values; the secret is pre-created and the chart's deployment auto-references it via `envFrom`.
- ACL must include `tagOwners: { tag:homelab: ["autogroup:admin"] }` — operator tags managed devices with `tag:homelab` (`operatorConfig.defaultTags` + `proxyConfig.defaultTags`).
- **`tailscale` namespace needs `pod-security.kubernetes.io/enforce: privileged`** — subnet-router pods use privileged containers (sysctls + raw networking). Symptom of missing this: `FailedCreate` on the StatefulSet with `violates PodSecurity "baseline:latest": privileged`.
- HA via 2 separate `Connector` CRs (subnet-router-a/b) advertising the same route. Tailscale handles failover between subnet routers automatically.
- Routes must be approved in the Tailscale admin UI after pods register — this is one-time manual.
- Split DNS in Tailscale admin forwards `*.internal.tylerrosnett.com` lookups to `192.168.1.1` (pfSense Unbound). Required so clients reaching the cluster over Tailscale resolve the internal hostnames correctly.

**Pattern for any operator with CRDs + CRs in this repo:** split into two Flux Kustomizations (operator-installs-CRDs first, CRs second with `dependsOn`). Don't put both in one kustomize bundle — Flux dry-run validation fails on the CRs before the CRDs land.

## Blocky DNS ad-blocking

`apps/blocky/` runs [Blocky](https://github.com/0xERR0R/blocky) as a LAN-wide DNS ad/tracker blocker. **Model A**: pfSense Unbound (192.168.1.1) stays the client-facing resolver and *forwards* upstream to Blocky; Blocky filters and forwards clean queries to Cloudflare DoT. Clients are unchanged (still use pfSense via DHCP); rollback = disable Unbound Forwarding Mode.

- Raw manifests (no first-party Helm chart). Config is a ConfigMap (`config.yml`); `queryLog.type: none` (no per-request logging by choice — aggregate Prometheus metrics only). Upstreams are Cloudflare DoT (`tcp-tls:1.1.1.1:853` / `1.0.0.1:853`). Denylists: StevenBlack + hagezi pro, with an inline allowlist for false positives.
- **2 replicas** with `requiredDuringScheduling` pod anti-affinity (DNS shouldn't flap on a node reboot). Namespace PSA is **`restricted`** — Blocky runs non-root and only needs `NET_BIND_SERVICE` (the one cap `restricted` permits) to bind :53.
- **DNS Service** is `LoadBalancer` at `192.168.1.202` (`lb-announce: "true"` for L2 announce), ports 53/UDP+TCP, default `externalTrafficPolicy` (`Cluster` — do NOT set `Local`, see L2 announcement scoping). Separate ClusterIP `blocky-metrics:4000` backs the ServiceMonitor (`release: kube-prometheus-stack`). No gateway HTTPRoute — Blocky has no web UI.
- Because of Model A, all queries reach Blocky from pfSense's IP, so there is no per-client granularity in metrics (consistent with the no-logging choice).

**pfSense forwarding-mode gotchas (don't re-derive):**
- **DNSSEC must be OFF.** Services → DNS Resolver → uncheck "Enable DNSSEC Support". Blocky returns synthetic `0.0.0.0` for blocked domains; Unbound with DNSSEC validation marks that bogus → **SERVFAIL on blocked domains only** (clean domains still resolve). This is the signature symptom. Encryption/validation still happens upstream at Blocky→Cloudflare DoT.
- **`private-domain` custom option needs an explicit `server:` prefix.** pfSense appends Custom Options at the end of `unbound.conf`; once Forwarding Mode injects a `forward-zone:` block, a bare `private-domain: "tylerrosnett.com"` lands in forward-zone context and Unbound rejects it (`syntax error`). Prefix the Custom Options block with `server:` to re-enter server context.
- **"Use SSL/TLS for outgoing queries" must stay OFF** — Blocky listens plain DNS on :53, not DoT on :853.
- Blocky must be the **only** DNS server in System → General; in forwarding mode Unbound races all listed servers, so a leftover `1.1.1.1` lets queries bypass the blocker. Also uncheck the WAN DNS override.
- Split-DNS host overrides (`*.internal.tylerrosnett.com`) still win — Unbound answers them locally before forwarding, so Blocky never sees them.

## Home Assistant + smart-plug energy monitoring

`apps/home-assistant/` runs HA as a plain container (no Supervisor → **no add-on store, no UI file editor**). `hostNetwork: true` + `ClusterFirstWithHostNet` so HA can do mDNS discovery of LAN devices (Shelly plugs, HomeKit). Exposed at `ha.internal.tylerrosnett.com` / `homeassistant.internal.tylerrosnett.com` via the internal gateway. Config lives on the Longhorn PVC, **not in git** — edit via `kubectl -n home-assistant exec -it deploy/home-assistant -- vi /config/configuration.yaml`.

Energy pipeline: Shelly Plug US Gen4 (LAN, static DHCP mappings at `192.168.1.250+`, hostnames `plug-<node>` registered in pfSense DNS) → HA Shelly integration → HA `prometheus:` integration → ServiceMonitor scrape → Grafana `Energy / Smart Plugs` dashboard (`extra-dashboards/dashboards/energy.json`).

Gotchas (don't re-derive):

- HA's `prometheus:` block in `configuration.yaml` uses `namespace: hass` → metrics are `hass_sensor_power_w`, `hass_sensor_energy_kwh`, `hass_binary_sensor_state` (community dashboards usually assume the default `homeassistant_` prefix).
- The `filter.include_entity_globs` must match **current entity IDs** (`sensor.homelab_plug_*`). Renaming entities in HA silently breaks the export — symptom is `up{job="home-assistant"} == 1` (endpoint healthy, `hass_area_info` present) but zero sensor metrics. The integration only reads config at startup: `kubectl -n home-assistant rollout restart deploy/home-assistant` after any change.
- ServiceMonitor lives in the `home-assistant` namespace because **the bearer-token Secret must be in the same namespace as the ServiceMonitor** (prometheus-operator constraint). Token is an HA long-lived access token, SOPS-encrypted at `apps/home-assistant/secrets/prometheus-token.sops.yaml`.
- The Service needs `labels: app: home-assistant` — ServiceMonitors select Services by label, and the original Service had none.
- Plugs are set to power-on default "On" and front-button lock (they feed cluster nodes/router); their `switch.*` entities are disabled in HA so nothing can toggle them. Factory reset: hold button 10s **within 60s of plug-in**.

## Uptime monitoring and Discord alerts

`observability/blackbox-exporter/` owns the uptime side end-to-end:

- **`prometheus-blackbox-exporter`** HelmRelease (community chart 11.10.0) with `http_2xx`, `http_2xx_insecure`, `tcp_connect` modules. ServiceMonitor enabled with `release: kube-prometheus-stack` label for KPS discovery.
- **`Probe` CRDs** in `probes.yaml` — split into `public-endpoints` (3 URLs) and `internal-endpoints` (5 URLs), 60s interval. Add targets to the static list; don't add new Probe resources unless you need different modules/labels.
- **`PrometheusRule`** in `rules.yaml` with 4 alerts: `EndpointDown`, `EndpointSlow`, `CertExpiringSoon`, `CertExpired`. All use `severity: warning|critical`.
- **`AlertmanagerConfig`** in `alertmanagerconfig.yaml` — single route with `severity =~ warning|critical` matcher routes to a `discord_configs` receiver. Webhook URL pulled from `secrets/discord-webhook.sops.yaml` via `apiURL.name/key` Secret ref.
- KPS values set `alertmanagerConfigSelector: { matchLabels: { alertmanagerConfig: discord } }` so the operator picks up the CRD. Required — by default KPS's selector matches nothing.
- **Watchdog is suppressed** by the severity matcher (it's `severity: none`). Don't broaden the matcher or Discord gets a heartbeat ping every 30s.
- **Live alert state is sticky** — Alertmanager keeps alerts in their original group until they resolve. After changing route matchers, restart the Alertmanager pod (`kubectl -n monitoring delete pod alertmanager-kube-prometheus-stack-alertmanager-0`) to force re-evaluation.
