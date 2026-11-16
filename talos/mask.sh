#!/usr/bin/env bash
# Mask secret values in Talos config text so it is safe to share.
# Each masked value becomes <masked:XXXXXXXX>, the first 8 hex digits of its SHA-256, so the
# same secret shows the same tag wherever it moves to, without revealing it.
# Usage: ./mask.sh [file]   Reads stdin when no file is given.
#   e.g. talosctl apply-config --dry-run ... | ./mask.sh
set -euo pipefail

exec python3 -I -c '
import hashlib, re, sys

secret_key = re.compile(
    r"^(?P<lead>[\s+-]*)(?P<key>[A-Za-z0-9_.]*(?:secret|token|crt|cert)[A-Za-z0-9_.]*"
    r"|ca|key|id|clusterID):\s+(?P<value>\S.*?)\s*$", re.IGNORECASE)
long_b64 = re.compile(r"[A-Za-z0-9+/=]{40,}")

def tag(value):
    value = value.strip("\"\x27")
    return "<masked:" + hashlib.sha256(value.encode()).hexdigest()[:8] + ">"

src = open(sys.argv[1]) if len(sys.argv) > 1 else sys.stdin
in_pem = False
for line in src:
    line = line.rstrip("\n")
    if "-----BEGIN " in line:
        in_pem = True
        print(line)
        continue
    if "-----END " in line:
        in_pem = False
        print(line)
        continue
    if in_pem:
        # Every body line of a PEM block, including the short last line.
        print(re.match(r"^[\s+-]*", line).group(0) + "<masked>")
        continue
    m = secret_key.match(line)
    if m and m.group("value") not in ("|", ">", "|-", ">-"):
        line = m.group("lead") + m.group("key") + ": " + tag(m.group("value"))
    print(long_b64.sub("<masked>", line))
' "$@"
