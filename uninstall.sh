#!/bin/bash
# Removes the Claude Account Switcher app. Your saved logins are kept unless you pass --all.
set -euo pipefail
APP="$HOME/Applications/Claude Account Switcher.app"
DATA="$HOME/Library/Application Support/ClaudeSwitcher"

pkill -x ClaudeSwitcher 2>/dev/null || true
rm -rf "$APP"
echo "Removed the app."

if [ "${1:-}" != "--all" ]; then
  echo "Your saved logins are still in: $DATA"
  echo "To delete them too, first switch to the account you want to keep, then run: ./uninstall.sh --all"
  exit 0
fi

printf '%s' "Delete all saved logins of accounts that are not active now? This cannot be undone. [y/N] "
read -r answer
[ "$answer" = "y" ] || [ "$answer" = "Y" ] || { echo "Nothing deleted."; exit 0; }
if [ -d "$DATA/accounts" ]; then
  for dir in "$DATA/accounts"/*/; do
    id="$(basename "$dir")"
    security delete-generic-password -s "ClaudeSwitcher CLI login" -a "$id" >/dev/null 2>&1 || true
  done
fi
if [ -d "$DATA/side" ]; then
  for dir in "$DATA/side"/*/; do
    service="Claude Code-credentials-$(printf '%s' "${dir%/}" | shasum -a 256 | cut -c1-8)"
    security delete-generic-password -s "$service" -a "$(whoami)" >/dev/null 2>&1 || true
  done
fi
mv "$DATA" "$HOME/.Trash/ClaudeSwitcher-$(date +%Y%m%d-%H%M%S)"
echo "Moved the switcher's data to the Trash. The Claude app and Claude Code keep their current login."
