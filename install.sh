#!/bin/sh
# Link this checkout into the machine-wide skills directory so every project
# can say "act as the manager". Re-runnable; refuses to clobber a real directory.
# Also links register-builder/ beside dest, so a builder session can ask to be
# adopted.
#
# usage: install.sh [dest] [--omp-extension] [--omp]
#
# --omp-extension also links extensions/mgr-status.ts into the omp agent
# directory (PI_CODING_AGENT_DIR, default ~/.omp/agent), which is how adopted
# and manager sessions get the status line; sessions started by `mgr launch`
# already load it from the checkout via --extension.
#
# --omp runs `bin/mgr-package setup` after linking: it installs the five size
# agents into that same omp agent directory and applies the model package for
# this machine's house (`mgr config get house`, else anthropic).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
omp_extension=0
omp_setup=0
dest=""

for arg in "$@"; do
  case "$arg" in
    --omp-extension) omp_extension=1;;
    --omp) omp_setup=1;;
    -h|--help)
      echo "usage: install.sh [dest] [--omp-extension] [--omp]"
      exit 0;;
    -*)
      echo "install: unknown option: $arg" >&2
      exit 2;;
    *) dest="$arg";;
  esac
done
[ -n "$dest" ] || dest="$HOME/.claude/skills/manager"

if [ -e "$dest" ] && [ ! -L "$dest" ]; then
  echo "install: $dest exists and is not a symlink; move it aside first" >&2
  exit 1
fi

skills_dir=$(dirname "$dest")
register_dest="$skills_dir/register-builder"
if [ -e "$register_dest" ] && [ ! -L "$register_dest" ]; then
  echo "install: $register_dest exists and is not a symlink; move it aside first" >&2
  exit 1
fi

mkdir -p "$skills_dir"
ln -sfn "$here" "$dest"
ln -sfn "$here/register-builder" "$register_dest"
chmod +x "$here/bin/mgr" "$here/bin/mgr-package"

for bin in gh jq git herdr; do
  command -v "$bin" >/dev/null 2>&1 || echo "install: warning: '$bin' not on PATH" >&2
done

echo "install: $dest -> $here"
echo "install: $register_dest -> $here/register-builder"

if [ "$omp_extension" = 1 ]; then
  agent_dir="${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}"
  ext_dest="$agent_dir/extensions/mgr-status.ts"
  if [ -e "$ext_dest" ] && [ ! -L "$ext_dest" ]; then
    echo "install: $ext_dest exists and is not a symlink; move it aside first" >&2
    exit 1
  fi
  mkdir -p "$agent_dir/extensions"
  ln -sfn "$here/extensions/mgr-status.ts" "$ext_dest"
  echo "install: $ext_dest -> $here/extensions/mgr-status.ts"
fi

if [ "$omp_setup" = 1 ]; then
  # the size agents and the house's model package, into the same agent dir
  "$here/bin/mgr-package" setup || {
    echo "install: mgr-package setup failed" >&2
    exit 1
  }
fi
