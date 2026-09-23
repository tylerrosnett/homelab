# Talos Configuration

Managed with [talhelper](https://github.com/budimanjojo/talhelper). The `talconfig.yaml` is the single source of truth for all node configuration.

## Prerequisites

```bash
brew install talosctl
brew install talhelper
```

## Generate secrets (first time only)

```bash
talhelper gensecret > talsecret.sops.yaml
sops -e -i talsecret.sops.yaml
```

## Generate per-node machine configs

```bash
talhelper genconfig
# outputs to ./clusterconfig/ (gitignored)
```

## Apply config to a node (maintenance mode)

```bash
# Confirm disk name first
talosctl disks --insecure --nodes <node-ip>

# Apply
talosctl apply-config --insecure --nodes <node-ip> --file ./clusterconfig/<hostname>.yaml
```

## Bootstrap etcd (first node only, after all 3 are up)

```bash
talosctl bootstrap --nodes 10.10.10.5
```

## Fetch kubeconfig

```bash
talosctl kubeconfig --nodes 10.10.10.246 --endpoints 10.10.10.246
```

## Node IPs

| Hostname | IP            | Role          |
|----------|---------------|---------------|
| oak      | 10.10.10.5   | controlplane  |
| maple    | 10.10.10.6   | controlplane  |
| pine     | 10.10.10.7   | controlplane  |
| VIP      | 10.10.10.246 | Kubernetes API|
