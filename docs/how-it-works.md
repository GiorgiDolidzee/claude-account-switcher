# How it works

## What a "login" is

Measured with the Step 0 script (see [step0.md](step0.md)) on Claude for Mac 5.11 and Claude Code 2.1. The result is [data/login-set.json](../data/login-set.json); it holds only file and key names.

**Claude desktop app** (`~/Library/Application Support/Claude`)
- The web storage: `Cookies`, `Local Storage`, `Session Storage`, `IndexedDB`, `WebStorage`, `blob_storage`.
- A few keys in `config.json` (the OAuth token cache and the last account id).
- The app keeps each account's sessions, plugins and workspaces in folders named by account id, so they never need to move.
- The app counts as logged in while its `sessionKey` cookie for claude.ai exists. Only cookie names are read, never values.

**Claude Code CLI**
- The Keychain item `Claude Code-credentials`.
- `oauthAccount` and a few account caches in `~/.claude.json`.
- The organization files `remote-settings*` and `policy-limits*` in `~/.claude`.

Nothing else moves: skills, plugins, `CLAUDE.md`, settings, history, projects and the VM stay where they are.

## A switch, step by step

1. Check that the Claude app and every main `claude` process are closed (it asks before closing them). Side terminals are left alone.
2. Read which account each side is on.
3. Write a journal entry, so an interrupted switch can be finished later.
4. Park the current login: move its files and keys to `~/Library/Application Support/ClaudeSwitcher/accounts/<account-id>/`, and copy the CLI secret to the Keychain item `ClaudeSwitcher CLI login` (read it back to check, then delete the original).
5. Put the chosen account's saved login in place the same way.
6. Clear the journal and open Claude.

Every step checks what is there before acting, so running it again after a crash finishes the switch. If a value exists in two places with different contents, it stops and changes nothing.

## Side-by-side terminal

Each account gets a folder `side/<account-id>/` used as `CLAUDE_CONFIG_DIR`. It links to your `CLAUDE.md`, settings, skills, plugins and projects in `~/.claude`, and has its own login (one `/login` the first time). It never shares a token with the main CLI, because two places using the same token would log one of them out.

## Files

```
~/Library/Application Support/ClaudeSwitcher/
  state.json          accounts and the switch journal (no secrets)
  login-set.json      what counts as a login
  accounts/<id>/      parked logins
  side/<id>/          side-terminal folders
  backup-<date>/      the safety copy made before the first switch
  stray-<date>/       anything unexpected; never deleted automatically
```
