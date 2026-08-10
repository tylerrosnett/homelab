# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

GitOps configuration for a 5-node Talos Linux Kubernetes homelab. Flat layout — everything cluster-related lives under `clusters/homelab/` (single cluster, no need to split apps from infra across directories):

- `talos/` — Talos node configuration via [talhelper](https://github.com/budimanjojo/talhelper); `talconfig.yaml` is the single source of truth.
- `clusters/homelab/flux-system/` — Flux bootstrap (flux-operator + FluxInstance) and root Kustomizations for the `homelab` cluster.
- `clusters/homelab/platform/` — Crossplane + the four Cloudflare providers (dns, zone, access, zero-trust) and their `ClusterProviderConfig`. Split across three Flux Kustomizations (operator → providers → provider-config) per the CRD/CR ordering pattern below.
- `clusters/homelab/cloudflare/` — Cloudflare DNS records managed as Crossplane CRs (`dns/email.yaml` MX+DKIM+SPF, `dns/wildcard.yaml`). Note this means DNS is *partly* GitOps-managed now; the per-app internal records still come from ExternalDNS.
- `clusters/homelab/network/` — CNI (Cilium), Gateway API CRDs, LB IP pool / L2 announce, Gateways (internal `*.ik8s` + public `*.k8s` for Cloudflare Tunnel), ExternalDNS, cloudflared, Tailscale operator + subnet-router Connectors.
- `clusters/homelab/security/` — cert-manager + ClusterIssuers, Kyverno (operator + audit-mode policies, split into two Flux Kustomizations per the CRD/CR ordering pattern below).
- `clusters/homelab/storage/` — Longhorn (+ HTTPRoute exposing the UI internally) and MinIO (standalone, S3 backend for Outline attachments; S3 API public at `files.tylerrosnett.com`, console internal).
- `clusters/homelab/observability/` — kube-prometheus-stack (Prometheus, Alertmanager, Grafana), Loki single-binary, Grafana Alloy DaemonSet, Flux PodMonitor + dashboards, blackbox-exporter (uptime probes + Discord alerts), extra-dashboards (cert-manager / Cilium / Longhorn / Node Exporter Full / Loki / Blackbox / Blocky / Energy JSONs as ConfigMaps).
- `clusters/homelab/system/` — cluster-level helpers (`kubelet-csr-approver`, `cluster-admin-oidc` for the SOPS-encrypted OIDC ClusterRoleBinding).
- `clusters/homelab/apps/` — workload manifests (deployments, services, HTTPRoutes, NetworkPolicies): `whoami`, `hello-public`, `game-2048`, `headlamp` (cluster-admin dashboard with CF Access OIDC, **LAN-only**), `home-assistant` (smart-home hub + smart-plug energy metrics source), `blocky`, `outline`, `minecraft`, `ntfy` (public push notifications at `ntfy.tylerrosnett.com`, deny-all auth with SOPS-provisioned users/tokens, `upstream-base-url` pointed at ntfy.sh for iOS delivery).
- `docs/` — gitignored local scratch, including the Aug 2026 remediation plans.
- `.github/workflows/` — PR validation (kustomize build, kubeconform, SOPS-encryption guard).
- `renovate.json` — config for the Mend-hosted Renovate GitHub App. Detects HelmRelease chart versions, OCI/HTTPS HelmRepositories, kustomize images, Crossplane provider packages, GHA digests, plus custom regex managers for `talosVersion:`/`kubernetesVersion:` in `talconfig.yaml`, the FluxInstance minor, and the flux-operator chart tag. Gateway API CRD bumps come from the flux manager watching the `gateway-api` GitRepository tag. Schedule is 6pm–5am weekdays plus weekends. **No automerge anywhere** — every PR is merged by hand on purpose. Renovate maintains a "Dependency Dashboard" issue tracking everything it finds.

Each subsystem follows the pattern: a directory with raw manifests + `kustomization.yaml`, and a sibling `<name>.yaml` Flux Kustomization wrapper that adds `dependsOn` and `decryption`. The root `clusters/homelab/kustomization.yaml` lists those wrappers.

**Do not add `healthChecks` to a wrapper.** Every wrapper sets `wait: true`, and Flux ignores `spec.healthChecks` entirely when `spec.wait` is true — `wait` already health-checks every resource the Kustomization applies. Declaring both reads like a cross-Kustomization ordering gate but silently is not one; use `dependsOn` for that.

## Cluster facts (don't re-derive)

- Controlplane nodes (bare metal, interface `eno1`): `oak` 192.168.1.5, `maple` 192.168.1.6, `pine` 192.168.1.7. Schedulable (`allowSchedulingOnControlPlanes: true`).
- Worker nodes (Proxmox VMs on the R640s, `deviceSelector: driver: virtio_net`): `birch` 192.168.1.10 (`homelab/node-class: game` — minecraft pins to it), `cedar` 192.168.1.11 (`homelab/node-class: bulk`).
- Kubernetes API VIP: `192.168.1.246` (Talos shared VIP on `eno1`).
- **Versions live in `talos/talconfig.yaml` and Renovate bumps them — read the file, don't trust a number written here.** Note that merging a Renovate Talos/k8s PR changes only git; the rollout (`talhelper genconfig` + `talosctl upgrade`) is manual and has historically lagged.
- CNI is `none` in Talos config — **Cilium is installed out-of-band**, so any networking work must account for Cilium being the actual CNI.
- `kube-proxy` is disabled (Cilium kube-proxy replacement expected). Cilium reaches the apiserver via **KubePrism** (`localhost:7445`), not the VIP: Talos moves the VIP on etcd health, not apiserver health, so a node with healthy etcd and a sick apiserver could otherwise stall every agent.
- Install disk on every node is selected by `installDiskSelector` (`size: '>= 200GB', type: ssd`) rather than a fixed `/dev/sdX` path — block device names aren't stable across reboots when USB media is present. Proxmox virtual disks need "SSD emulation" ticked for `type: ssd` to match. System extensions: `iscsi-tools`, `util-linux-tools` everywhere, plus `qemu-guest-agent` on workers.
- Kubelet uses `rotate-server-certificates: true`.
- The apiserver audit policy logs Secrets at **`Metadata`** level, deliberately. `RequestResponse` would write every SOPS-decrypted value Flux applies into the node audit log in plaintext — and Alloy tails that log into Loki. Don't raise it.

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
- Private key backups (2026-08-03): Apple Passwords and Bitwarden. To restore, place the `AGE-SECRET-KEY-1...` line in `~/.config/sops/age/keys.txt` and check it with `age-keygen -y` against the recipient above.
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
- **Loki retention is compactor-based** (`loki.compactor.retention_enabled: true` + `delete_request_store: filesystem` + `limits_config.retention_period: 30d`). Loki refuses to start with retention enabled and no delete-request store. Without retention the 50Gi PVC grows until ingestion stops, silently.
- **ServiceMonitors default to OFF in the Loki, Longhorn and cert-manager charts** and are explicitly enabled in each HelmRelease. If a provisioned dashboard is permanently empty, check that first. cert-manager's values key is lowercase `prometheus.servicemonitor.enabled` — the camelCase spelling silently does nothing.
- **Prometheus sets both `retention: 14d` and `retentionSize: "45GiB"`** on a 50Gi PVC. The size backstop matters because time-based retention alone won't save you from a scrape-volume spike.
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

## Kyverno admission policy

`security/kyverno/` (operator, CRDs) and `security/kyverno-policies/` (prebuilt Pod Security Standards `restricted` set + 4 custom ClusterPolicies) are two Flux Kustomizations per the CRD/CR ordering pattern. **Everything runs `validationFailureAction: Audit` with `failurePolicy: Ignore` — nothing blocks admission.** Violations land in PolicyReports: `kubectl get polr -A` (namespaced) and `kubectl get cpolr` (cluster-scoped, where the Namespace-targeted policy reports).

- Custom policies: `require-pinned-images` (tag must match `:v?[0-9]...` or be digest-pinned; heuristic), `require-probes` (any one of liveness/readiness/startup — faithful copy of the upstream policy, deliberately looser than "readiness and liveness"), `require-requests` (CPU + memory requests), `require-cnp-in-public-namespaces` (background apiCall scan; report-only by nature since the namespace exists before its CNP).
- The apiCall policy depends on the `cilium.io` RBAC `extraResources` set on **both** admissionController and reportsController in the operator HelmRelease. Removing it makes background scans silently error.
- Six namespaces carry `expose-public: "true"` and are in the CNP policy's scope: hello-public, game-2048, outline, minio, monitoring, ntfy.
- Expected audit violators, all deliberate: home-assistant (loose on purpose), monitoring's node-exporter, longhorn-system, assorted chart-managed jobs.
- **Enforce flip order, per policy:** zero FAILs in reports → set `admissionController.replicas: 3` (a single replica with a failing-closed webhook blocks all admission when its pod dies) → flip the policy (`spec.validationFailureAction: Enforce` + `spec.failurePolicy: Fail` for custom; `validationFailureActionByPolicy` for PSS) → exempt accepted violators via `validationFailureActionOverrides`.

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

## ntfy push notifications

`apps/ntfy/` runs [ntfy](https://ntfy.sh) publicly at `ntfy.tylerrosnett.com` (cf-tunnel). Nothing in-cluster publishes to it yet — Discord keeps the Alertmanager traffic.

- **Auth is deny-all** with users/tokens provisioned declaratively from the SOPS secret via `NTFY_AUTH_USERS` / `NTFY_AUTH_TOKENS` env vars (`user:bcrypt-hash:role` / `user:token[:label]`). Provisioned tokens must be `tk_` + 29 lowercase alphanumerics. Generate the hash with `podman run --rm -it docker.io/binwiederhier/ntfy:v2.27.0 user hash` (the `user` command exists only in the Linux server build — macOS brew ntfy is client-only).
- **Credential rotation needs `kubectl -n ntfy rollout restart deploy/ntfy`** — nothing annotates the Deployment with a secret checksum, so editing the SOPS file alone changes nothing in the running pod.
- `upstream-base-url: https://ntfy.sh` is required for iOS delivery: ntfy.sh relays a wake-up through APNS, then the phone fetches the message from this server.
- The CNP allows the gateway entities plus a `fromEndpoints` rule for Prometheus. Any future in-cluster publisher (e.g. Alertmanager) needs its own `fromEndpoints` rule — `fromEntities` alone drops pod-to-pod traffic (the MinIO helper-job lesson).
- Deployment uses `strategy: Recreate` (RWO Longhorn PVC) — same RollingUpdate deadlock avoidance as Grafana.

## Uptime monitoring and Discord alerts

`observability/blackbox-exporter/` owns the uptime side end-to-end:

- **`prometheus-blackbox-exporter`** HelmRelease (community chart; version lives in the HelmRelease, Renovate bumps it) with `http_2xx`, `http_2xx_insecure`, `tcp_connect` modules. ServiceMonitor enabled with `release: kube-prometheus-stack` label for KPS discovery. This repo's `http_2xx` accepts `[200, 301, 302, 401, 403]`, which is why probing an endpoint that 403s on `GET /` (e.g. MinIO's S3 API at `files.tylerrosnett.com`) is safe rather than a permanent false alarm.
- **`Probe` CRDs** in `probes.yaml` — split into `public-endpoints` and `internal-endpoints`, 60s interval. Add targets to the static list; don't add new Probe resources unless you need different modules/labels.
- **`PrometheusRule`** in `rules.yaml` with 4 alerts: `EndpointDown`, `EndpointSlow`, `CertExpiringSoon`, `CertExpired`. All use `severity: warning|critical`. `CertExpiringSoon` is bounded to `> 0 and < 14d` so it doesn't swallow `CertExpired`. Note `CertExpired` still can't fire under `http_2xx`: an expired cert fails the handshake, so `probe_ssl_earliest_cert_expiry` stops being reported instead of going negative, and `EndpointDown` fires. Switching those probes to `http_2xx_insecure` would be the real fix.
- **Platform alerts** live separately in `observability/kube-prometheus-stack/prometheusrule-platform.yaml` (Flux reconcile failures, Longhorn volume health, cert-manager renewal, Loki). **Flux exports no `gotk_resource_info` or `gotk_reconcile_condition`** — the controllers only emit `gotk_reconcile_duration_seconds` and `controller_runtime_*`, so alerts there are built on `controller_runtime_reconcile_total{result="error"}` and `up`. Resource-state metrics would need kube-state-metrics `customResourceState` config, which doesn't exist here (that's also why `flux-monitoring/dashboards/cluster.json` renders empty).
- **`AlertmanagerConfig`** in `alertmanagerconfig.yaml` — single route with `severity =~ warning|critical` matcher routes to a `discord_configs` receiver. Webhook URL pulled from `secrets/discord-webhook.sops.yaml` via `apiURL.name/key` Secret ref.
- KPS values set `alertmanagerConfigSelector: { matchLabels: { alertmanagerConfig: discord } }` so the operator picks up the CRD. Required — by default KPS's selector matches nothing.
- **Watchdog is suppressed** by the severity matcher (it's `severity: none`). Don't broaden the matcher or Discord gets a heartbeat ping every 30s.
- **Live alert state is sticky** — Alertmanager keeps alerts in their original group until they resolve. After changing route matchers, restart the Alertmanager pod (`kubectl -n monitoring delete pod alertmanager-kube-prometheus-stack-alertmanager-0`) to force re-evaluation.
