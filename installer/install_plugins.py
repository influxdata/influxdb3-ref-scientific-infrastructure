"""Install Processing Engine plugins from the InfluxDB 3 plugin registry.

Runs as the one-shot `plugin-installer` compose service, after the influxdb3
server starts and before triggers are registered. For every plugin pinned in
`plugins.lock` it:

1. resolves the pinned (name, version) against the registry index,
2. downloads `{artifacts_url}/{name}-{version}.tar.gz`,
3. verifies the artifact sha256 against the index entry's `hash`,
4. classifies the entry point (single-file vs multi-file),
5. uploads every file via POST /api/v3/plugins/files with
   `plugin_name = "{name}-{version}/<relative_path>"` (the path relative to the
   server's --plugin-dir),
6. installs the entry's `dependencies.python` via
   POST /api/v3/configure/plugin_environment/install_packages
   (unless the lock entry sets `install_deps = false`).

Repo-local plugins (none in this repo; LOCAL_PLUGINS_DIR is optional) would be uploaded through the
same files endpoint under `local/<filename>`.

Deliberately simple — this is a reference architecture, not a product backend:
one registry, pinned versions, and overwrite-on-every-boot idempotency (there
is no reliable way to list what is already on the server's filesystem, so we
just re-upload; pinned artifacts make that a byte-identical no-op).

Only Python stdlib. Set INSTALLER_OFFLINE_DIR to a directory containing
pre-downloaded `{name}-{version}.tar.gz` artifacts to skip registry downloads
(the sha256 check still applies when the index is reachable; fully offline
falls back to trusting the local artifacts).
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import sys
import tarfile
import time
import tomllib
import urllib.error
import urllib.request

DEFAULT_INDEX_URL = (
    "https://github.com/influxdata/influxdb3_plugins/releases/download/registry/index.json"
)

RETRY_ATTEMPTS = 60
RETRY_SLEEP_S = 2.0


def log(msg: str) -> None:
    print(f"[installer] {msg}", flush=True)


def fatal(msg: str) -> None:
    print(f"[installer] FATAL: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Token handling
# ---------------------------------------------------------------------------


def read_admin_token(token_file: str) -> str:
    """Extract the token string from the JSON file token-bootstrap wrote."""
    with open(token_file, encoding="utf-8") as f:
        data = json.load(f)
    token = data.get("token")
    if not token:
        fatal(f"no 'token' key in {token_file}")
    return token


def ensure_plain_token(token: str, plain_file: str | None) -> None:
    """Write the plain-text token used by container healthchecks.

    The influxdb3 healthcheck reads this file; writing it here (before the
    server can pass its healthcheck) is what lets `depends_on: service_healthy`
    consumers start.
    """
    if not plain_file:
        return
    if os.path.exists(plain_file) and os.path.getsize(plain_file) > 0:
        return
    with open(plain_file, "w", encoding="utf-8") as f:
        f.write(token)
    # 644, not 600: this container runs as root but the influxdb3 container's
    # healthcheck cats this file as a non-root user. The volume itself is the
    # security boundary here (demo scope; see ARCHITECTURE.md §11).
    os.chmod(plain_file, 0o644)
    log(f"wrote plain token for healthchecks: {plain_file}")


# ---------------------------------------------------------------------------
# HTTP helpers (stdlib only)
# ---------------------------------------------------------------------------


def http_get(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "influxdb3-ref-sci-installer"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read()


def api_post(base_url: str, path: str, token: str, body: dict) -> None:
    url = f"{base_url}{path}"
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        resp.read()


def wait_for_api(base_url: str, token: str) -> None:
    """Poll /health until the server answers. Gates on service_started only,
    so the server may still be coming up (or waiting on license validation —
    which can take as long as the user takes to click the email link)."""
    last_err: Exception | None = None
    # License validation is interactive; wait generously (30 min).
    for attempt in range(900):
        try:
            req = urllib.request.Request(
                f"{base_url}/health", headers={"Authorization": f"Bearer {token}"}
            )
            with urllib.request.urlopen(req, timeout=3) as resp:
                resp.read()
            return
        except Exception as e:  # noqa: BLE001 — retry loop
            last_err = e
            if attempt % 15 == 0:
                log(f"waiting for influxdb3 API ({e})")
            time.sleep(RETRY_SLEEP_S)
    fatal(f"influxdb3 API never became ready: {last_err}")


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------


def load_lock(lock_file: str) -> dict:
    with open(lock_file, "rb") as f:
        return tomllib.load(f)


def fetch_index(index_url: str) -> dict | None:
    try:
        raw = http_get(index_url)
    except (urllib.error.URLError, OSError) as e:
        log(f"registry index unreachable ({e})")
        return None
    return json.loads(raw)


def resolve_entry(index: dict, name: str, version: str) -> dict:
    for entry in index.get("plugins", []):
        if entry.get("name") == name and entry.get("version") == version:
            if entry.get("yanked"):
                fatal(f"{name}-{version} is yanked in the registry; bump the pin in plugins.lock")
            return entry
    fatal(f"{name}-{version} not found in registry index")
    raise AssertionError  # unreachable


def fetch_artifact(index: dict | None, name: str, version: str, offline_dir: str) -> bytes:
    filename = f"{name}-{version}.tar.gz"
    if offline_dir:
        path = os.path.join(offline_dir, filename)
        if os.path.exists(path):
            log(f"{filename}: using offline artifact {path}")
            with open(path, "rb") as f:
                return f.read()
    if index is None:
        fatal(f"registry unreachable and no offline artifact for {filename}")
    artifacts_url = index["artifacts_url"].rstrip("/")
    url = f"{artifacts_url}/{filename}"
    log(f"downloading {url}")
    return http_get(url)


def verify_hash(blob: bytes, entry: dict | None, name: str, version: str) -> None:
    if entry is None:
        log(f"{name}-{version}: index unreachable, skipping hash verification (offline mode)")
        return
    expected = entry.get("hash", "")
    if not expected.startswith("sha256:"):
        fatal(f"{name}-{version}: index hash has unexpected format: {expected!r}")
    actual = "sha256:" + hashlib.sha256(blob).hexdigest()
    if actual != expected:
        fatal(
            f"{name}-{version}: artifact hash mismatch — refusing to install\n"
            f"  expected {expected}\n  actual   {actual}"
        )
    log(f"{name}-{version}: sha256 verified")


# ---------------------------------------------------------------------------
# Artifact contents
# ---------------------------------------------------------------------------


def extract_files(blob: bytes) -> dict[str, str]:
    """Return {relative_path: content} for every regular file in the tarball.

    Handles both flat archives and archives wrapped in a single top-level
    directory (the relative paths are normalized either way). Contents are
    read in-memory; nothing touches the local filesystem, which also
    sidesteps tar path-traversal concerns.
    """
    files: dict[str, str] = {}
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
        members = [m for m in tar.getmembers() if m.isfile()]
        names = [m.name.removeprefix("./") for m in members]
        # Strip a shared single top-level directory if present.
        prefixes = {n.split("/", 1)[0] for n in names if "/" in n}
        strip = None
        if len(prefixes) == 1 and all("/" in n for n in names):
            strip = next(iter(prefixes)) + "/"
        for member, name in zip(members, names, strict=True):
            rel = name[len(strip) :] if strip and name.startswith(strip) else name
            if not rel or rel.startswith("/") or ".." in rel.split("/"):
                fatal(f"artifact contains a suspicious path: {member.name!r}")
            fobj = tar.extractfile(member)
            if fobj is None:
                continue
            raw = fobj.read()
            try:
                files[rel] = raw.decode("utf-8")
            except UnicodeDecodeError:
                log(f"skipping non-text file {rel} ({len(raw)} bytes)")
    if not files:
        fatal("artifact contained no uploadable files")
    return files


def classify_entry_point(files: dict[str, str], name: str) -> str:
    """Return the plugin's entry file relative path.

    Per the registry plugin-format rules:
    - a root `__init__.py` means multi-file (the directory is the entry point),
    - exactly one root `.py` means single-file,
    - anything else is an error.
    """
    root_py = [p for p in files if "/" not in p and p.endswith(".py")]
    if "__init__.py" in root_py:
        return "__init__.py"
    if len(root_py) == 1:
        return root_py[0]
    fatal(f"{name}: cannot classify entry point (root .py files: {root_py})")
    raise AssertionError  # unreachable


# ---------------------------------------------------------------------------
# Upload + deps
# ---------------------------------------------------------------------------


def upload_files(base_url: str, token: str, prefix: str, files: dict[str, str]) -> None:
    for rel, content in sorted(files.items()):
        plugin_name = f"{prefix}/{rel}" if prefix else rel
        api_post(
            base_url,
            "/api/v3/plugins/files",
            token,
            {
                "plugin_name": plugin_name,
                "content": content,
            },
        )
        log(f"uploaded {plugin_name}")


def install_python_deps(base_url: str, token: str, name: str, packages: list[str]) -> None:
    if not packages:
        return
    log(f"{name}: installing python deps {packages}")
    api_post(
        base_url,
        "/api/v3/configure/plugin_environment/install_packages",
        token,
        {
            "packages": packages,
        },
    )
    log(f"{name}: python deps installed")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> None:
    base_url = os.environ.get("INFLUX_URL", "http://influxdb3:8181").rstrip("/")
    token_file = os.environ.get("TOKEN_FILE", "/tokens/.sci-operator-token")
    plain_file = os.environ.get("TOKEN_PLAIN_FILE", "")
    lock_file = os.environ.get("LOCK_FILE", "/installer/plugins.lock")
    local_dir = os.environ.get("LOCAL_PLUGINS_DIR", "")
    index_url = os.environ.get("REGISTRY_INDEX_URL", DEFAULT_INDEX_URL)
    offline_dir = os.environ.get("INSTALLER_OFFLINE_DIR", "")

    token = read_admin_token(token_file)
    ensure_plain_token(token, plain_file)
    wait_for_api(base_url, token)

    lock = load_lock(lock_file)
    pins = lock.get("plugin", [])
    log(f"{len(pins)} registry plugin(s) pinned in {lock_file}")

    index = fetch_index(index_url)

    for pin in pins:
        name, version = pin["name"], pin["version"]
        entry = resolve_entry(index, name, version) if index is not None else None
        blob = fetch_artifact(index, name, version, offline_dir)
        verify_hash(blob, entry, name, version)
        files = extract_files(blob)
        entry_file = classify_entry_point(files, name)
        prefix = f"{name}-{version}"
        upload_files(base_url, token, prefix, files)
        log(f"{name}: entry point {prefix}/{entry_file}")
        if pin.get("install_deps", True):
            deps = (entry or {}).get("dependencies", {}).get("python", [])
            deps = deps or pin.get("python_deps", [])
            install_python_deps(base_url, token, name, deps)
        else:
            log(f"{name}: deps deferred (install_deps = false)")

    if local_dir and os.path.isdir(local_dir):
        local_files = {}
        for fn in sorted(os.listdir(local_dir)):
            if fn.endswith(".py"):
                with open(os.path.join(local_dir, fn), encoding="utf-8") as f:
                    local_files[fn] = f.read()
        log(f"{len(local_files)} local plugin(s) in {local_dir}")
        upload_files(base_url, token, "local", local_files)

    log("done")


if __name__ == "__main__":
    main()
