# Talos configuration

`genconfig.sh` renders each node's machine config from the files in this directory with
`talosctl gen config` and `talosctl machineconfig patch`. It needs `talosctl`, `sops` (with
the age key) and `curl`. No third-party config tool is involved.

## Layout

| Path | What it holds |
|------|---------------|
| `versions.env` | Cluster name, API endpoint, Talos and Kubernetes versions. Renovate bumps the versions here. |
| `talsecret.sops.yaml` | The cluster secrets bundle (SOPS-encrypted), in `talosctl gen secrets` format. |
| `patches/all/` | Patches for every node. |
| `patches/controlplane/`, `patches/worker/` | Patches for one role. |
| `nodes/<role>/<node>.yaml` | One patch per node: hostname, network, VIP, install disk. The folder sets the node's role. |
| `schematics/<role>.yaml`, `schematics/<node>.yaml` | Image Factory customizations (system extensions). A node file replaces its role's file. |
| `clusterconfig/` | Rendered output. Gitignored, owner-only. Never commit it. |

The script applies patches in file-name order, `patches/all/` first, then the role folder,
then the node's own file last. It decrypts any file ending in `.sops.yaml` into a temporary
folder inside `clusterconfig/` and deletes that folder when it exits.

Write patches in the Talos 1.14 multi-document layout (`KubeletConfig`,
`UnattendedInstallConfig`, `KubeNodeConfig` and so on). Talos rejects a config that sets the
same thing in both the old `machine:`/`cluster:` fields and a new document.

## Render

```bash
./genconfig.sh            # every node, plus clusterconfig/talosconfig
./genconfig.sh oak        # one node only
```

## Check before applying

`dryrun.sh` shows what applying a rendered config would change on a running node, with
secret values replaced by short fingerprints so you can share the output:

```bash
./dryrun.sh oak 10.10.10.5
```

Read the whole diff before you apply. After applying, the dry run must report `No changes`.

`diffconfig.sh <a> <b>` compares two rendered files the same way, and `mask.sh` masks any
Talos config text you pipe into it. `talosctl apply-config --dry-run` prints its diff on
stderr, so pipe with `2>&1` if you run it by hand.

## Apply

```bash
talosctl apply-config -n <ip> -e <ip> -f clusterconfig/homelab-<node>.yaml
```

For a new machine in maintenance mode, add `--insecure` and confirm the install disk first:

```bash
talosctl get disks --insecure -n <ip> -o yaml
```

## Bootstrap etcd (first control plane only, once)

```bash
talosctl bootstrap -n 10.10.10.5 -e 10.10.10.5
```

## Fetch kubeconfig

```bash
talosctl kubeconfig -n 10.10.10.246 -e 10.10.10.246
```

## New secrets bundle (new cluster only)

```bash
talosctl gen secrets -o talsecret.sops.yaml && sops -e -i talsecret.sops.yaml
```

## Nodes

| Hostname | IP | Role |
|----------|----|------|
| oak | 10.10.10.5 | controlplane |
| maple | 10.10.10.6 | controlplane |
| pine | 10.10.10.7 | controlplane |
| VIP | 10.10.10.246 | Kubernetes API |
