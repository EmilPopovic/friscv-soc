#!/usr/bin/env bash
# Copyright 2026 FER, HPC Architecture and Application Research Center
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#
# Emil Popović <mail@emilpopovic.me>

set -euo pipefail

FOSSI_SUBSTITUTER="https://nix-cache.fossi-foundation.org"
FOSSI_KEY="nix-cache.fossi-foundation.org:3+K59iFwXqKsL7BNu6Guy0v+uTlwsxYQxjspXzqLYQs="
NIX_FLAGS="--extra-experimental-features nix-command --extra-experimental-features flakes"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: 'curl' is required. Install it with your package manager and re-run." >&2
    exit 1
fi

if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi

if ! command -v nix >/dev/null 2>&1; then
    echo "Nix not found - installing, the installer will ask for sudo."
    curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | \
        sh -s -- install --no-confirm \
            --extra-conf "extra-substituters = ${FOSSI_SUBSTITUTER}" \
            --extra-conf "extra-trusted-public-keys = ${FOSSI_KEY}"
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
else
    echo "Found $(nix --version)"
fi

NIX_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/nix/nix.conf"
mkdir -p "$(dirname "$NIX_CONF")"
if ! grep -qs "nix-cache.fossi-foundation.org" "$NIX_CONF" 2>/dev/null; then
    {
        echo "extra-substituters = ${FOSSI_SUBSTITUTER}"
        echo "extra-trusted-public-keys = ${FOSSI_KEY}"
    } >> "$NIX_CONF"
    echo "Added the FOSSi cache to ${NIX_CONF}."
fi

if [ ! -f flake.lock ]; then
    echo "Locking flake inputs..."
    nix $NIX_FLAGS flake lock
fi

if ! nix $NIX_FLAGS profile list 2>/dev/null | grep -q nix-direnv; then
    echo "Installing nix-direnv into user profile..."
    nix $NIX_FLAGS profile install nixpkgs#nix-direnv
fi
DIRENVRC="${XDG_CONFIG_HOME:-$HOME/.config}/direnv/direnvrc"
mkdir -p "$(dirname "$DIRENVRC")"
if ! grep -qs 'nix-direnv/direnvrc' "$DIRENVRC" 2>/dev/null; then
    echo 'source "$HOME/.nix-profile/share/nix-direnv/direnvrc"' >> "$DIRENVRC"
fi

echo
echo "All set."
echo

if command -v direnv >/dev/null 2>&1; then
    echo "Activate with:  direnv allow"
    echo "Add to your shell rc:"
    echo '  eval "$(direnv hook zsh)"      # for ~/.zshrc'
    echo '  eval "$(direnv hook bash)"     # for ~/.bashrc'
else
    echo "direnv is not installed. Install it via your package manager and add its shell hook, then run 'direnv allow'."
fi
