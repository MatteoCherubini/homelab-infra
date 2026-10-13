#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  host-config-copy.sh — another machine's configuration,      ║
# ║  copied to the server for the nightly backup                 ║
# ╚══════════════════════════════════════════════════════════════╝
#
# Runs on the LAPTOP, not on the server. The server holds no key that opens
# the firewall or the hypervisor, by design: a compromised server must not
# hand them over too. So the copy is taken by hand, through the SSH aliases
# the laptop already has, after every change to a machine and at the
# quarterly session. docs/backup.md, "Other machines".
#
# Usage:
#   ./scripts/host-config-copy.sh <profile> <ssh-alias> <server>:<directory>
#
# <profile> names a list, backup/hosts/<profile>.paths. The archive streams
# from the machine straight to <directory>/<ssh-alias>/ on the server, so
# nothing lands on the laptop. On the server it is tested (gzip -t), renamed
# from .part only once complete, and given a .sha256 that
# `make backup-restore-test` checks after the round trip off-site.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
HOSTS_DIR="$(pwd)/backup/hosts"

die() { echo "host-config-copy: $*" >&2; exit 1; }
[ $# -eq 3 ] || { sed -n '13,14p' "${BASH_SOURCE[0]}" >&2; exit 2; }

profile=$1 alias=$2 dest=$3
server=${dest%%:*} dir=${dest#*:}
list="$HOSTS_DIR/$profile.paths"
[[ $profile =~ ^[a-z0-9-]+$ ]] && [ -f "$list" ] || die "no profile '$profile' under backup/hosts/"
[[ $alias =~ ^[A-Za-z0-9._-]+$ ]] || die "not an ssh alias: $alias"
[[ $dest == *:* && $server =~ ^[A-Za-z0-9._@-]+$ ]] || die "the destination is <server>:<directory>"
[[ $dir =~ ^/[A-Za-z0-9._/-]+$ && $dir != *..* ]] || die "the directory must be an absolute path: $dir"

# Every word below is wrapped in single quotes once and read by the machine's
# login shell, whatever it is — sh, bash, or csh on a firewall — so the
# characters a path may hold are few.
path_re='^[?]?(/|~/)[A-Za-z0-9._/-]+$'
quoted=()
while IFS= read -r p; do
  [[ $p =~ $path_re && $p != *..* ]] || die "$list: unsupported path: $p"
  quoted+=("'$p'")
done < <(sed -e 's/[[:space:]]*#.*//' -e '/^[[:space:]]*$/d' "$list")
[ ${#quoted[@]} -gt 0 ] || die "$list lists no path"

# On the machine: `?` marks a path that may be absent, `~/` the login user's
# home. A required path that is missing stops everything before a byte is sent.
# shellcheck disable=SC2016  # expanded on the machine, not here
remote='set -u; cd / || exit 1; ok=1; list=; for p; do opt=0; case $p in "?"*) opt=1; p=${p#?};; esac; case $p in "~/"*) p=$HOME/${p#??};; esac; if [ -e "$p" ] || [ -L "$p" ]; then list="$list ${p#/}"; elif [ $opt = 0 ]; then echo "missing: $p" >&2; ok=0; else echo "skipped, absent: $p" >&2; fi; done; [ $ok = 1 ] || exit 3; [ -n "$list" ] || { echo "none of the paths exists" >&2; exit 3; }; exec tar -czf - $list'

# On the server: owner-only from the first byte; a stream that breaks leaves
# nothing behind.
# shellcheck disable=SC2016  # expanded on the server, not here
receive='set -eu; umask 077; d=$1/$2; f=$3; mkdir -p "$d" || { echo "create $1 once, owned by this account: docs/backup.md, Other machines" >&2; exit 1; }; chmod 700 "$1" "$d"; trap "rm -f \"$d/$f.part\"" EXIT; cat > "$d/$f.part"; gzip -t "$d/$f.part"; n=$(tar -tzf "$d/$f.part" | wc -l); mv "$d/$f.part" "$d/$f"; cd "$d"; sha256sum "$f" > "$f.sha256"; printf "%s, %s entries, sha256 %s\n" "$d/$f" "$n" "$(cut -c1-16 "$f.sha256")"'

file="$alias-$(date +%Y-%m-%dT%H%M%S).tar.gz"
result=$(mktemp)   # one line of text, never the data
trap 'rm -f "$result"' EXIT

echo "$alias ($profile, ${#quoted[@]} paths) → $server:$dir/$alias/" >&2
set +e
ssh -o ConnectTimeout=10 "$alias" "sh -c '$remote' sh ${quoted[*]}" \
  | ssh -o ConnectTimeout=10 "$server" "sh -c '$receive' sh '$dir' '$alias' '$file'" >"$result"
status=("${PIPESTATUS[@]}")
set -e

# When one side stops, the other fails too (a cut stream, a broken pipe):
# the first error printed above is the cause.
if [ "${status[1]}" -ne 0 ]; then
  die "nothing was kept: $alias exited ${status[0]}, the server ${status[1]}; the first error above is the cause"
fi
if [ "${status[0]}" -ne 0 ]; then
  # The archive arrived whole, but tar skipped a file it could not read: an
  # incomplete configuration must not pass for a good one.
  ssh -o ConnectTimeout=10 "$server" "rm -f '$dir/$alias/$file' '$dir/$alias/$file.sha256'" || true
  die "$alias reported an error (exit ${status[0]}); the copy was removed, the error is above"
fi
echo "ok: $(cat "$result")"
echo "The nightly backup takes it off-site; make backup-restore-test checks it." >&2
