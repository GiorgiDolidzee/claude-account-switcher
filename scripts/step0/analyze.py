#!/usr/bin/python3 -I
"""Step 0 analysis: compares the snapshots and proposes the login set.

Works on names and hashes only. Writes report.md and login-set.proposed.json.
"""
import argparse
import datetime
import json
import os
import re
import subprocess

WEB_STORAGE = ["Cookies", "Cookies-journal", "Local Storage", "Session Storage",
               "IndexedDB", "WebStorage", "blob_storage"]
SHARED_HOME = ["CLAUDE.md", "settings.json", "statusline.sh", "skills", "plugins", "agents",
               "commands", "hooks", "projects", "plans"]
WATCH_FILES = ["buddy-tokens.json", "ant-device-registry.json", "ant-did",
               "remote-control-state.json", "Local State"]
LABELS = ["S1", "S2", "S3", "S4", "C2", "C3", "C4"]
PER_ORG = re.compile(r":[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
ACCOUNT_ID_KEY = "lastKnownAccountUuid"


def same(a, b):
    if a.get("type") == "dir" and b.get("type") == "dir":
        return True
    for field in ("type", "size", "sha", "empty"):
        if a.get(field) != b.get(field):
            return False
    if "size" in a and a.get("sha") is None and a.get("mtime") != b.get("mtime"):
        return False
    return True


def changed(a, b):
    """Names added, removed or different between two name->info maps."""
    out = set()
    for name in set(a) | set(b):
        if name.startswith("_error"):
            continue
        if name not in a or name not in b or not same(a[name], b[name]):
            out.add(name)
    return out


def login_changes(noise_pair, steps):
    noise = changed(*noise_pair)
    found = set()
    for pair in steps:
        found |= changed(*pair)
    return sorted(found - noise), sorted(noise)


def filled(keys, name):
    return name in keys and not keys[name].get("empty", True)


def describe(name, before, after):
    if name not in before:
        return "added"
    if name not in after:
        return "removed"
    return "changed"


def cli_versions(paths):
    out = {}
    for path in paths:
        if not os.path.exists(path):
            continue
        try:
            result = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=30)
            out[path] = result.stdout.strip().splitlines()[0] if result.stdout.strip() else "?"
        except (OSError, subprocess.TimeoutExpired):
            out[path] = "?"
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--dir", required=True)
    p.add_argument("--cli-path", action="append", default=[])
    a = p.parse_args()

    snaps = {}
    for label in LABELS:
        with open(os.path.join(a.dir, label + ".json")) as f:
            snaps[label] = json.load(f)

    def app(label, part):
        return snaps[label]["app"][part]

    def cli(label, part):
        return snaps[label]["cli"][part]

    key_login, key_noise = login_changes(
        (app("S1", "configKeys"), app("S2", "configKeys")),
        [(app("S2", "configKeys"), app("S3", "configKeys")),
         (app("S3", "configKeys"), app("S4", "configKeys"))])
    file_login, _ = login_changes(
        (app("S1", "files"), app("S2", "files")),
        [(app("S2", "files"), app("S3", "files")), (app("S3", "files"), app("S4", "files"))])
    cjson_login, cjson_noise = login_changes(
        (cli("S4", "claudeJsonKeys"), cli("C2", "claudeJsonKeys")),
        [(cli("C2", "claudeJsonKeys"), cli("C3", "claudeJsonKeys")),
         (cli("C3", "claudeJsonKeys"), cli("C4", "claudeJsonKeys"))])
    home_login, _ = login_changes(
        (cli("S4", "claudeHomeTop"), cli("C2", "claudeHomeTop")),
        [(cli("C2", "claudeHomeTop"), cli("C3", "claudeHomeTop")),
         (cli("C3", "claudeHomeTop"), cli("C4", "claudeHomeTop"))])

    per_org = [k for k in key_login if PER_ORG.search(k)]
    config_keys = [k for k in key_login if k not in per_org]
    token_keys = [k for k in config_keys if k.startswith("oauth:")]
    # Anything /logout removes belongs to the login, even if it also changes on a quiet run.
    removed_keys = set(cli("C2", "claudeJsonKeys")) - set(cli("C3", "claudeJsonKeys"))
    removed_home = set(cli("C2", "claudeHomeTop")) - set(cli("C3", "claudeHomeTop"))
    claude_json_keys = sorted(set(["oauthAccount"]) | set(cjson_login) | removed_keys)
    home_items = sorted(n for n in set(home_login) | removed_home if n not in SHARED_HOME and n != "history.jsonl")

    # The app is logged in while this cookie exists (config keys stay filled after a log out).
    def cookie_names(label):
        return {c.split("\t")[1] for c in app(label, "cookies")
                if "\t" in c and c.split("\t")[0].endswith("claude.ai")}
    login_cookie = "sessionKey" if "sessionKey" in (cookie_names("S2") - cookie_names("S3")) else None

    versions = cli_versions(a.cli_path)
    proposed = {
        "schemaVersion": 1,
        "measuredAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "claudeAppVersion": snaps["S4"].get("appVersion") or "unknown",
        "claudeCliVersion": ", ".join(sorted(set(versions.values()))) or "unknown",
        "app": {"items": WEB_STORAGE, "configKeys": config_keys,
                "accountIdKey": ACCOUNT_ID_KEY, "tokenKeys": token_keys,
                "loginCookie": {"hostSuffix": "claude.ai", "name": login_cookie or "sessionKey"}},
        "cli": {"keychainService": "Claude Code-credentials",
                "claudeJsonKeys": claude_json_keys, "claudeHomeItems": home_items},
    }

    lines = ["# Step 0 report", ""]
    lines.append("Claude app version: %s" % proposed["claudeAppVersion"])
    for path, version in sorted(versions.items()):
        lines.append("CLI %s: %s" % (path, version))
    lines.append("Snapshots: " + ", ".join("%s %s" % (l, snaps[l]["takenAt"]) for l in LABELS))
    lines += ["", "## Checks", ""]

    def check(ok, text):
        lines.append("%s — %s" % ("OK" if ok else "CHECK", text))

    if ACCOUNT_ID_KEY not in config_keys:
        lines.append("ERROR — %s is not among the keys that change at log out / log in" % ACCOUNT_ID_KEY)
    if not token_keys:
        lines.append("ERROR — no oauth: token key changes at log out / log in")

    if login_cookie is None:
        lines.append("ERROR — the sessionKey cookie on claude.ai did not disappear at log out")
    rule = ["sessionKey" in cookie_names(label) for label in ("S1", "S2", "S3", "S4")]
    check(rule == [True, True, False, True],
          "logged-in rule (sessionKey cookie on claude.ai): S1..S4 = %s, expected yes yes no yes"
          % " ".join("yes" if r else "no" for r in rule))

    def login_cookies(label):
        return {c for c in app(label, "cookies")
                if "claude.ai" in c.split("\t")[0] or "anthropic.com" in c.split("\t")[0]}
    gone = login_cookies("S2") - login_cookies("S3")
    back = login_cookies("S4") - login_cookies("S3")
    check(bool(gone) and bool(back),
          "login cookies leave at log out and come back at log in. Gone: %s. Back: %s"
          % (", ".join(sorted(c.replace("\t", " / ") for c in gone)) or "none",
             ", ".join(sorted(c.replace("\t", " / ") for c in back)) or "none"))

    kc = [cli(l, "keychainItemExists") for l in ("S4", "C2", "C3", "C4")]
    check(kc == [True, True, False, True],
          "CLI Keychain item: S4 C2 C3 C4 = %s, expected yes yes no yes"
          % " ".join("yes" if k else "no" for k in kc))
    oa = ["oauthAccount" in cli(l, "claudeJsonKeys") for l in ("C2", "C3", "C4")]
    check(oa == [True, False, True],
          "oauthAccount in ~/.claude.json: C2 C3 C4 = %s, expected yes no yes"
          % " ".join("yes" if o else "no" for o in oa))
    sizes = [cli(l, "keychainSecretBytes") for l in LABELS if cli(l, "keychainSecretBytes")]
    if sizes:
        biggest = max(sizes)
        fits = 2 * biggest + 90 <= 4000
        check(fits, "CLI secret size: %d bytes — %s in one security -i line"
              % (biggest, "fits" if fits else "does NOT fit"))
    else:
        lines.append("CHECK — CLI secret size: not measured")

    lines += ["", "## Proposed app login set", "", "Web storage items (moved whole):"]
    for item in WEB_STORAGE:
        info = app("S4", "webStorage").get(item, {})
        lines.append("- %s (%s)" % (item, "%d files, %d bytes" % (info.get("files", 0), info.get("bytes", 0))
                                    if info.get("exists") else "not present"))
    lines += ["", "config.json keys that change at log out / log in:"]
    for key in config_keys:
        lines.append("- %s (log out: %s, log in: %s)" % (
            key, describe(key, app("S2", "configKeys"), app("S3", "configKeys")),
            describe(key, app("S3", "configKeys"), app("S4", "configKeys"))))
    lines += ["", "## config.json keys left alone: already per org", ""]
    lines += ["- %s" % k for k in per_org] or ["- none"]
    lines += ["", "## Needs a person to decide", "",
              "Files outside web storage that changed at log out or log in, but not in the quiet run:", ""]
    for name in file_login:
        mark = "  <-- look at this one" if os.path.basename(name) in WATCH_FILES and "/" not in name else ""
        lines.append("- %s (log out: %s, log in: %s)%s" % (
            name, describe(name, app("S2", "files"), app("S3", "files")) if name in changed(app("S2", "files"), app("S3", "files")) else "same",
            describe(name, app("S3", "files"), app("S4", "files")) if name in changed(app("S3", "files"), app("S4", "files")) else "same",
            mark))
    if not file_login:
        lines.append("- none")
    lines += ["", "## Proposed CLI login set", "", "~/.claude.json keys:"]
    lines += ["- %s" % k for k in claude_json_keys]
    lines += ["", "~/.claude top-level items:"]
    lines += ["- %s" % n for n in home_items] or ["- none"]
    lines += ["", "Organization files (remote-settings*, policy-limits*):"]
    org_files = sorted(n for l in ("C2", "C3", "C4") for n in cli(l, "claudeHomeTop")
                       if n.startswith("remote-settings") or n.startswith("policy-limits"))
    for name in sorted(set(org_files)):
        lines.append("- %s (log out: %s, log in: %s)" % (
            name,
            describe(name, cli("C2", "claudeHomeTop"), cli("C3", "claudeHomeTop")) if name in changed(cli("C2", "claudeHomeTop"), cli("C3", "claudeHomeTop")) else "same",
            describe(name, cli("C3", "claudeHomeTop"), cli("C4", "claudeHomeTop")) if name in changed(cli("C3", "claudeHomeTop"), cli("C4", "claudeHomeTop")) else "same"))
    if not org_files:
        lines.append("- none found")
    lines += ["", "## Quiet-run noise (ignored)", "",
              "config.json: " + (", ".join(key_noise) or "none"),
              "~/.claude.json: " + (", ".join(cjson_noise) or "none"), ""]

    for name, text in (("report.md", "\n".join(lines)),
                       ("login-set.proposed.json", json.dumps(proposed, indent=2) + "\n")):
        path = os.path.join(a.dir, name)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(text)
    print("Report saved: %s" % os.path.join(a.dir, "report.md"))


if __name__ == "__main__":
    main()
