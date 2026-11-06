#!/bin/zsh
set -euo pipefail

GITHUBBAR_VERSION=0.1.0 scripts/package-validation.sh
pkill -f '/GitDock.app/Contents/MacOS/GitDock' 2>/dev/null || true
exec .build/validation/GitDock.app/Contents/MacOS/GitDock
