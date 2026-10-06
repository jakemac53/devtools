#!/bin/bash
# Copyright 2026 The Flutter Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

# Installs the DevTools GenUI plugin for Antigravity / Jetski.
#
# Symlinks ~/.gemini/config/plugins/devtools_genui to the submitted copy of
# this plugin at google3 head, so you pick up updates automatically.
#
# Usage:
#   install.sh              Link to google3 head (recommended).
#   install.sh --local      Link to the directory containing this script (for
#                           developing the plugin in a CitC workspace).
#   install.sh --uninstall  Remove the link.
set -euo pipefail

readonly HEAD_DIR="/google/src/files/head/depot/google3/experimental/users/jakemac/devtools_genui"
readonly DEST="${HOME}/.gemini/config/plugins/devtools_genui"

case "${1:-}" in
  "")
    SOURCE="${HEAD_DIR}"
    ;;
  --local)
    SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ;;
  --uninstall)
    if [[ -L "${DEST}" ]]; then
      rm "${DEST}"
      echo "Removed ${DEST}"
    else
      echo "${DEST} is not installed (or is not a symlink); nothing to do."
    fi
    exit 0
    ;;
  *)
    echo "Usage: $0 [--local | --uninstall]" >&2
    exit 2
    ;;
esac

if [[ ! -f "${SOURCE}/plugin.json" ]]; then
  echo "Can't find the plugin at ${SOURCE}." >&2
  exit 1
fi

if ! command -v node > /dev/null; then
  echo "Warning: 'node' isn't on your PATH. The side pane needs Node.js" \
    "(sudo apt install nodejs)." >&2
fi

mkdir -p "$(dirname "${DEST}")"
if [[ -e "${DEST}" && ! -L "${DEST}" ]]; then
  echo "${DEST} already exists and is not a symlink; remove it first." >&2
  exit 1
fi
ln -sfn "${SOURCE}" "${DEST}"
echo "Linked ${DEST} -> ${SOURCE}"
echo "Next: make sure the \"devtools_genui\" plugin is enabled in Jetski (run" \
  "/plugin in a chat), then ask the agent for a DevTools view of your app."
