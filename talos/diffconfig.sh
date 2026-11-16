#!/usr/bin/env bash
# Compare two rendered Talos configs with secret values masked, so the output is safe to share.
# Usage: ./diffconfig.sh <a> <b>   Exit 0 if identical, 1 if they differ.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ $# -eq 2 ] || { echo "usage: $0 <a> <b>" >&2; exit 2; }
a="$1"; b="$2"
for f in "$a" "$b"; do [ -f "$f" ] || { echo "diffconfig: no such file: $f" >&2; exit 2; }; done

cmp -s "$a" "$b" && exit 0

if diff <("$here/mask.sh" "$a") <("$here/mask.sh" "$b"); then
  echo "diffconfig: files differ only in masked (secret) values" >&2
fi
exit 1
