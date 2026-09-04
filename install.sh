#!/bin/sh
# Link this checkout into the machine-wide skills directory so every project
# can say "act as the manager". Re-runnable; refuses to clobber a real directory.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
dest="${1:-$HOME/.claude/skills/manager}"

if [ -e "$dest" ] && [ ! -L "$dest" ]; then
  echo "install: $dest exists and is not a symlink; move it aside first" >&2
  exit 1
fi

mkdir -p "$(dirname "$dest")"
ln -sfn "$here" "$dest"
chmod +x "$here/bin/mgr"

for bin in gh jq git herdr; do
  command -v "$bin" >/dev/null 2>&1 || echo "install: warning: '$bin' not on PATH" >&2
done

echo "install: $dest -> $here"
