#!/usr/bin/python3 -I
"""Step 0 snapshot: records names, sizes, dates and short hashes only.

It never records file contents, cookie values, key values or secrets.
"""
import argparse
import datetime
import getpass
import hashlib
import json
import os
import plistlib
import sqlite3
import stat
import subprocess

WEB_STORAGE = ["Cookies", "Cookies-journal", "Local Storage", "Session Storage",
               "IndexedDB", "WebStorage", "blob_storage"]
NO_HASH = {"Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache",
           "GraphiteDawnCache", "GPUPersistentCache", "Crashpad", "sentry", "vm_bundles",
           "claude-code", "claude-code-vm", "claude-code-spare", "fcache"}
MAX_HASH_BYTES = 4 * 1024 * 1024
KEYCHAIN_SERVICE = "Claude Code-credentials"


def short_hash(data):
    return hashlib.sha256(data).hexdigest()[:16]


def file_hash(path):
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                digest.update(chunk)
    except OSError:
        return None
    return digest.hexdigest()[:16]


def is_empty(value):
    return value is None or value == "" or value == [] or value == {}


def json_keys(path):
    """Key names of a JSON object file, each with a hash of its value."""
    try:
        with open(path, "rb") as f:
            obj = json.load(f)
    except FileNotFoundError:
        return {"_error": "missing"}
    except (ValueError, OSError):
        return {"_error": "invalid"}
    if not isinstance(obj, dict):
        return {"_error": "invalid"}
    out = {}
    for key, value in obj.items():
        canonical = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        out[key] = {"sha": short_hash(canonical), "empty": is_empty(value)}
    return out


def entry(path, hash_it):
    st = os.lstat(path)
    if stat.S_ISLNK(st.st_mode):
        return {"type": "link", "size": st.st_size, "mtime": int(st.st_mtime), "sha": None}
    if stat.S_ISDIR(st.st_mode):
        return {"type": "dir", "size": 0, "mtime": int(st.st_mtime), "sha": None}
    sha = file_hash(path) if hash_it and st.st_size <= MAX_HASH_BYTES else None
    return {"type": "file", "size": st.st_size, "mtime": int(st.st_mtime), "sha": sha}


def app_files(app_dir):
    files = {}
    for top in sorted(os.listdir(app_dir)) if os.path.isdir(app_dir) else []:
        if top in WEB_STORAGE:
            continue
        top_path = os.path.join(app_dir, top)
        hash_it = top not in NO_HASH
        if os.path.islink(top_path) or not os.path.isdir(top_path):
            try:
                files[top] = entry(top_path, hash_it)
            except OSError:
                pass
            continue
        for folder, dirs, names in os.walk(top_path, followlinks=False):
            for name in names + [d for d in dirs if os.path.islink(os.path.join(folder, d))]:
                full = os.path.join(folder, name)
                try:
                    files[os.path.relpath(full, app_dir)] = entry(full, hash_it)
                except OSError:
                    pass
    return files


def web_storage(app_dir):
    out = {}
    for item in WEB_STORAGE:
        path = os.path.join(app_dir, item)
        if not os.path.lexists(path):
            out[item] = {"exists": False, "files": 0, "bytes": 0}
            continue
        count, total = 0, 0
        if os.path.isdir(path):
            for folder, _, names in os.walk(path):
                for name in names:
                    try:
                        total += os.lstat(os.path.join(folder, name)).st_size
                        count += 1
                    except OSError:
                        pass
        else:
            count, total = 1, os.lstat(path).st_size
        out[item] = {"exists": True, "files": count, "bytes": total}
    return out


def cookie_names(app_dir):
    """Cookie hosts and names only. Values are never selected."""
    path = os.path.join(app_dir, "Cookies")
    if not os.path.exists(path):
        return ["_error:missing"]
    try:
        db = sqlite3.connect("file:" + path.replace("?", "%3f").replace("#", "%23")
                             + "?mode=ro&immutable=1", uri=True)
        try:
            rows = db.execute("SELECT DISTINCT host_key, name FROM cookies").fetchall()
        finally:
            db.close()
    except sqlite3.Error as error:
        return ["_error:" + type(error).__name__]
    return sorted({"%s\t%s" % (host, name) for host, name in rows})


def keychain(security, user):
    base = [security, "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", user]
    try:
        found = subprocess.run(base, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               timeout=30).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False, None
    if not found:
        return False, None
    try:
        result = subprocess.run(base + ["-w"], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return True, None
    size = len(result.stdout.rstrip(b"\n")) if result.returncode == 0 else None
    del result  # only the length is kept
    return True, size


def claude_home_top(home):
    out = {}
    for name in sorted(os.listdir(home)) if os.path.isdir(home) else []:
        try:
            out[name] = entry(os.path.join(home, name), True)
        except OSError:
            pass
    return out


def app_version(bundle):
    try:
        with open(os.path.join(bundle, "Contents", "Info.plist"), "rb") as f:
            return plistlib.load(f).get("CFBundleShortVersionString")
    except (OSError, ValueError, plistlib.InvalidFileException):
        return None


def main():
    home = os.path.expanduser("~")
    p = argparse.ArgumentParser()
    p.add_argument("--label", required=True)
    p.add_argument("--out-dir", required=True)
    p.add_argument("--app-dir", default=os.path.join(home, "Library/Application Support/Claude"))
    p.add_argument("--claude-home", default=os.path.join(home, ".claude"))
    p.add_argument("--claude-json", default=os.path.join(home, ".claude.json"))
    p.add_argument("--security", default="/usr/bin/security")
    p.add_argument("--user", default=getpass.getuser())
    p.add_argument("--app-bundle", default="/Applications/Claude.app")
    a = p.parse_args()

    exists, secret_bytes = keychain(a.security, a.user)
    snapshot = {
        "label": a.label,
        "takenAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "appVersion": app_version(a.app_bundle),
        "app": {
            "files": app_files(a.app_dir),
            "webStorage": web_storage(a.app_dir),
            "configKeys": json_keys(os.path.join(a.app_dir, "config.json")),
            "cookies": cookie_names(a.app_dir),
        },
        "cli": {
            "claudeJsonKeys": json_keys(a.claude_json),
            "keychainItemExists": exists,
            "keychainSecretBytes": secret_bytes,
            "claudeHomeTop": claude_home_top(a.claude_home),
        },
    }
    os.makedirs(a.out_dir, mode=0o700, exist_ok=True)
    os.chmod(a.out_dir, 0o700)
    path = os.path.join(a.out_dir, a.label + ".json")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(snapshot, f, indent=1, sort_keys=True)
    os.chmod(path, 0o600)
    print("Snapshot %s saved." % a.label)


if __name__ == "__main__":
    main()
