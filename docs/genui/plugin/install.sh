#!/bin/bash
# Copyright 2026 The Flutter Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file or at https://developers.google.com/open-source/licenses/bsd.

# Installs the DevTools GenUI plugin for Antigravity / Jetski by symlinking this
# directory into ~/.gemini/config/plugins/, so local edits apply directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${HOME}/.gemini/config/plugins/devtools_genui"

mkdir -p "$(dirname "${DEST}")"
if [[ -e "${DEST}" && ! -L "${DEST}" ]]; then
  echo "${DEST} already exists and is not a symlink; remove it first." >&2
  exit 1
fi
ln -sfn "${SCRIPT_DIR}" "${DEST}"
echo "Linked ${DEST} -> ${SCRIPT_DIR}"
echo "Enable \"devtools_genui\" under UI Plugins, then ask the agent for a DevTools view."
