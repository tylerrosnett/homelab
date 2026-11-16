#!/usr/bin/env bash
# Render per-node Talos machine configs into clusterconfig/ (gitignored).
# Usage: ./genconfig.sh [node ...]   No arguments renders every node under nodes/*/ plus talosconfig.
# Needs talosctl, sops (with the age key) and curl.
set -euo pipefail
umask 077

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$here/clusterconfig"

die() { echo "genconfig: $*" >&2; exit 1; }

for tool in talosctl sops curl; do
  command -v "$tool" >/dev/null || die "$tool not found on PATH"
done

[ -f "$here/versions.env" ] || die "versions.env not found"
set -a; . "$here/versions.env"; set +a
for v in CLUSTER_NAME CLUSTER_ENDPOINT TALOS_VERSION KUBERNETES_VERSION; do
  [ -n "${!v:-}" ] || die "$v missing from versions.env"
done

# Decrypted secrets live only here: inside the gitignored output dir, owner-only, removed on any exit.
mkdir -p "$out"
chmod 700 "$out"
work="$(mktemp -d "$out/.work-XXXXXX")"
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT TERM

# Path where the plaintext copy of an input file lives (the file itself unless it is SOPS-encrypted).
plain() {
  case "$1" in
    *.sops.yaml) echo "$work/dec/$(echo "${1#"$here"/}" | tr '/' '_')" ;;
    *) echo "$1" ;;
  esac
}

decrypt() {
  local dest
  dest="$(plain "$1")"
  mkdir -p "$work/dec"
  sops --decrypt "$1" > "$dest" 2> "$work/sops.err" || {
    cat "$work/sops.err" >&2
    die "could not decrypt ${1#"$here"/}"
  }
}

decrypt "$here/talsecret.sops.yaml"
secrets="$(plain "$here/talsecret.sops.yaml")"
for f in "$here"/patches/*/*.sops.yaml; do
  if [ -e "$f" ]; then decrypt "$f"; fi
done

schematic_id() {
  curl -fsS --max-time 30 -X POST --data-binary "@$1" https://factory.talos.dev/schematics \
    | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{64\}\)".*/\1/p'
}

# Which nodes to render.
nodes=()
if [ $# -eq 0 ]; then
  for f in "$here"/nodes/*/*.yaml; do if [ -e "$f" ]; then nodes+=("$f"); fi; done
else
  for name in "$@"; do
    match=("$here"/nodes/*/"$name".yaml)
    [ -e "${match[0]}" ] || die "no node file nodes/*/$name.yaml"
    nodes+=("${match[0]}")
  done
fi
[ ${#nodes[@]} -gt 0 ] || die "no nodes found under nodes/"

gen_args() {
  # $1 = role. Fills the global array "args" with the shared gen config flags.
  local role="$1" roleflag p
  case "$role" in
    controlplane) roleflag=--config-patch-control-plane ;;
    worker) roleflag=--config-patch-worker ;;
    *) die "unknown role folder nodes/$role" ;;
  esac
  args=(
    --with-secrets "$secrets"
    --talos-version "$TALOS_VERSION"
    --kubernetes-version "${KUBERNETES_VERSION#v}"
    --with-docs=false
    --with-examples=false
  )
  for p in "$here"/patches/all/*.yaml; do if [ -e "$p" ]; then args+=(--config-patch "@$(plain "$p")"); fi; done
  for p in "$here/patches/$role"/*.yaml; do if [ -e "$p" ]; then args+=("$roleflag" "@$(plain "$p")"); fi; done
}

for file in "${nodes[@]}"; do
  node="$(basename "$file" .yaml)"
  role="$(basename "$(dirname "$file")")"

  schem="$here/schematics/$node.yaml"
  [ -f "$schem" ] || schem="$here/schematics/$role.yaml"
  [ -f "$schem" ] || die "no schematic for $node (schematics/$node.yaml or schematics/$role.yaml)"
  id="$(schematic_id "$schem")" || die "Image Factory request failed for ${schem#"$here"/}"
  [ -n "$id" ] || die "Image Factory returned no schematic ID for ${schem#"$here"/}"

  gen_args "$role"
  talosctl gen config "$CLUSTER_NAME" "$CLUSTER_ENDPOINT" "${args[@]}" \
    --install-image "factory.talos.dev/metal-installer/$id:$TALOS_VERSION" \
    --output-types "$role" --output "$work/$node.base.yaml" >/dev/null
  talosctl machineconfig patch "$work/$node.base.yaml" --patch "@$file" --output "$work/$node.yaml"
  talosctl validate --mode metal --config "$work/$node.yaml" >/dev/null || die "rendered config for $node failed validation"

  mv "$work/$node.yaml" "$out/homelab-$node.yaml"
  echo "rendered clusterconfig/homelab-$node.yaml (schematic $id)"
done

if [ $# -eq 0 ]; then
  gen_args controlplane
  talosctl gen config "$CLUSTER_NAME" "$CLUSTER_ENDPOINT" "${args[@]}" \
    --output-types talosconfig --output "$work/talosconfig" >/dev/null
  mv "$work/talosconfig" "$out/talosconfig"
  echo "rendered clusterconfig/talosconfig"
fi
