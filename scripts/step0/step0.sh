#!/bin/bash
# Step 0: measure what a Claude login is made of.
# Run this in Terminal.app (not inside Claude). It records names, sizes, dates
# and fingerprints only. It never records passwords, cookies or tokens.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HOME/Library/Application Support/ClaudeSwitcher/step0"
APP_DIR="$HOME/Library/Application Support/Claude"
PY=(/usr/bin/python3 -I)

say() { printf '\n%s\n' "$*"; }
wait_enter() { printf '%s' "Press Enter when done... "; read -r _; }

claude_running() {
  ps -axo comm= | grep -qE "^(/Applications/Claude\.app/|$APP_DIR/)"
}

snapshot() {
  while claude_running; do
    say "Claude is still running. Quit it (Cmd+Q), wait a few seconds."
    wait_enter
  done
  sleep 2
  "${PY[@]}" "$HERE/snapshot.py" --label "$1" --out-dir "$OUT"
}

run_cli() {
  if ! command -v claude >/dev/null 2>&1; then
    say "The 'claude' command was not found. Install Claude Code first, then run this again."
    exit 1
  fi
  env -u CLAUDE_CONFIG_DIR claude || true
}

mkdir -p "$OUT"
chmod 700 "$HOME/Library/Application Support/ClaudeSwitcher" "$OUT"

say "STEP 0 - this takes about 10 minutes."
echo "It saves only names, sizes, dates and fingerprints."
echo "It never saves passwords, cookies or tokens."
echo "You need TWO Claude accounts: the one you use now, and one other."
echo "Claude will be closed a few times. Save your work first."

say "1 of 8.  Quit Claude now (Cmd+Q)."
wait_enter
snapshot S1

say "2 of 8.  Open Claude. Wait until it has loaded. Do NOTHING else. Then quit Claude (Cmd+Q)."
wait_enter
snapshot S2

say "3 of 8.  Open Claude. LOG OUT. Then quit Claude (Cmd+Q)."
wait_enter
snapshot S3

say "4 of 8.  Open Claude. Log in to your OTHER account. Wait until it has loaded. Then quit Claude (Cmd+Q)."
wait_enter
snapshot S4

say "5 of 8.  Claude Code starts now in this window. When it has loaded, type:  /exit"
wait_enter
run_cli
snapshot C2

say "6 of 8.  Claude Code starts again. Type:  /logout   (if it is still open after that, type /exit)"
wait_enter
run_cli
snapshot C3

say "7 of 8.  Claude Code starts again. Log in with your OTHER account. When it has loaded, type:  /exit"
wait_enter
run_cli
snapshot C4

CLI_ARGS=()
for p in "$(command -v claude || true)" "$HOME/.local/bin/claude" /opt/homebrew/bin/claude; do
  [ -n "$p" ] && [ -e "$p" ] && CLI_ARGS+=(--cli-path "$p")
done
"${PY[@]}" "$HERE/analyze.py" --dir "$OUT" ${CLI_ARGS[@]+"${CLI_ARGS[@]}"}

echo
echo "Report: $OUT/report.md"
SWITCHER="$HOME/Library/Application Support/ClaudeSwitcher"
if grep -q "^ERROR\|^CHECK" "$OUT/report.md"; then
  say "Some checks did not pass (see the report). The login set was NOT changed."
else
  printf '\n%s' "All checks passed. Use the new measurement in Claude Account Switcher? [y/N] "
  read -r answer
  if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
    [ -f "$SWITCHER/login-set.json" ] && cp "$SWITCHER/login-set.json" "$SWITCHER/login-set.previous.json"
    install -m 600 "$OUT/login-set.proposed.json" "$SWITCHER/login-set.json"
    echo "Saved. Quit and open Claude Account Switcher to use it."
  fi
fi

say "8 of 8.  Last step (not measured): open Claude, LOG OUT, and log in again to the account you started with."
echo "Done. You can close this window."
