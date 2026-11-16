#!/usr/bin/env bash
# Show what applying a rendered config would change on a node, with secrets masked.
# talosctl prints the config diff on stderr, so both streams go through mask.sh.
# Usage: ./dryrun.sh <node> <ip>   e.g. ./dryrun.sh oak 10.10.10.5
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ $# -eq 2 ] || { echo "usage: $0 <node> <ip>" >&2; exit 2; }
node="$1"; ip="$2"
cfg="$here/clusterconfig/homelab-$node.yaml"
[ -f "$cfg" ] || { echo "dryrun: $cfg not found; run ./genconfig.sh first" >&2; exit 2; }

talosctl apply-config --dry-run -n "$ip" -e "$ip" -f "$cfg" 2>&1 | "$here/mask.sh"
