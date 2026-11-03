#!/usr/bin/env python3
"""Install, enrol and activate KH Updater on this Mac, from the SSD kit.

**This is the same client Studio Hub runs**, not a second one.
`components/hub/backend/khu_agent.py`'s `Bootstrap.install / enrol / activate` is mirrored here
step for step: the same `~/Library/KHUpdater` layout, the same config fields in the same order,
the same `com.khupdater.agent.plist` launchd label, the same publisher checks. That matters because
the two paths can both run on one Mac - Studio Hub auto-installs the agent on Hub Macs, and this kit
installs it on Macs that run only Story Studio or only GatewayKH. Whichever runs first installs;
the other finds it already there and does nothing. Two clients that produced *similar* installs
would give two different answers to "is the agent installed on this Mac".

It is a copy and not an import because the kit has to work where no Studio Hub is installed to
import from.

Three deliberate differences, all of them about being a one-shot run started by a person rather
than a background loop:

* enrolment is synchronous (no asyncio) and uses `urllib` from the standard library, because the
  kit cannot ship `httpx`;
* a run that fails *after* it has written something moves what it wrote to `~/Library/_trash`
  instead of leaving a half-install behind (the Hub keeps its partial state and retries every five
  minutes; a file someone double-clicked does not) - **except a failed agent start**, which is not
  a failed install: the files and the launchd job are finished, so they stay and the run prints
  launchctl's own reason and the one command that retries it (the same rule as kh-updater's
  `install-agent.sh`, owner 2026-10-26);
* the machine name is settled here - asked for and confirmed - rather than passed in.

The Ed25519 verification at the bottom is the `verify` half of
`components/hub/backend/ed25519.py` (RFC 8032, `hashlib` only) and nothing else. The signing half
has no business on a drive that is handed out to Macs.
"""
from __future__ import annotations

import base64
import fcntl
import hashlib
import json
import os
import plistlib
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

#: Exactly what `khu_agent.KIT_FILES` accepts. The two readers must agree byte for byte, so the
#: drive's `khu-agent/` is also a valid kit for Studio Hub should one ever be copied into a bundle.
KIT_FILES = {"VERSION", "bin/khu", "bin/khu-stub", "install-agent.sh",
             "com.khupdater.agent.plist", "agent-config.example.json", "publisher.json"}
LAUNCHD_LABEL = "com.khupdater.agent"
PLIST_NAME = LAUNCHD_LABEL + ".plist"
#: The Hub's own rule for its `controller_id` (`control_plane.ID_PATTERN`).
ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]{0,99}$")
HUB_BUNDLE_ID = "local.studiohub.standalone"


class StartFailed(ValueError):
    """The install finished; launchd refused to start it. Carries launchctl's own words."""

    def __init__(self, reason: str, plist: Path):
        super().__init__(reason)
        self.plist = plist


# --------------------------------------------------------------------------- small file helpers
def preserve(path: Path, root: Path) -> None:
    bucket = root / "_trash" / secrets.token_hex(12)
    bucket.mkdir(parents=True, mode=0o700)
    shutil.move(str(path), str(bucket / path.name))


def private_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink():
        raise ValueError("unsafe config path")
    fd, name = tempfile.mkstemp(prefix=".khu-", dir=path.parent)
    with os.fdopen(fd, "w") as stream:
        json.dump(value, stream)
        stream.flush()
        os.fsync(stream.fileno())
    if path.exists():
        preserve(path, path.parent)
    os.replace(name, path)


def version(value: str) -> tuple[int, ...]:
    if not re.fullmatch(r"[0-9]{1,9}(\.[0-9]{1,9}){0,5}", value):
        raise ValueError("invalid agent version")
    values = tuple(map(int, value.split(".")))
    return values + (0,) * (6 - len(values))


def safe_id(value: str, fallback: str = "studiohub") -> str:
    """The Hub's own name rule (`control_plane._safe_id`): lowercase, and only `a-z0-9._-`."""
    cleaned = re.sub(r"[^a-z0-9._-]+", "-", str(value or "").strip().lower()).strip("-._")
    return cleaned[:100] if cleaned and ID_PATTERN.fullmatch(cleaned[:100]) else fallback


# --------------------------------------------------------------------------- the publisher
def publisher_config(raw: dict, *, allow_test: bool = False) -> dict:
    if set(raw) != {"feedURL", "enrolURL", "publicKey", "testAuthority"}:
        raise ValueError("invalid publisher configuration")
    if type(raw["testAuthority"]) is not bool or (raw["testAuthority"] and not allow_test):
        raise ValueError("test authority cannot enrol a real Hub")
    try:
        key = base64.b64decode(raw["publicKey"], validate=True)
    except (ValueError, TypeError):  # base64.binascii.Error is a ValueError
        raise ValueError("invalid public key") from None
    if len(key) != 32:
        raise ValueError("invalid public key")
    import ipaddress
    addresses = []
    # The publisher serves the feed and enrolment on ONE port (8790), not one each.
    for key_name, path in (("feedURL", "/release.json"), ("enrolURL", "/enrol")):
        parsed = urlsplit(raw[key_name])
        address = ipaddress.ip_address(parsed.hostname or "")
        # In test mode, accept loopback OR Tailscale; otherwise require the Tailscale range and
        # port 8790.
        if (parsed.scheme != "http" or parsed.username or parsed.password or parsed.query
                or parsed.fragment or parsed.path != path
                or (not allow_test and (address not in ipaddress.ip_network("100.64.0.0/10")
                                        or parsed.port != 8790))
                or (allow_test and not (address.is_loopback
                                        or address in ipaddress.ip_network("100.64.0.0/10")))):
            raise ValueError("publisher must use its configured Tailscale address on port 8790")
        addresses.append(address)
    if addresses[0] != addresses[1]:
        raise ValueError("publisher origins disagree")
    return raw


def verify_kit(kit: Path, *, allow_test: bool = False) -> dict:
    if kit.is_symlink() or not kit.is_dir():
        raise ValueError("agent kit missing")
    manifest = json.loads((kit / "MANIFEST.json").read_text())
    files = manifest["files"]
    if set(files) != KIT_FILES:
        raise ValueError("unexpected agent kit contents")
    # Finder drops a .DS_Store in any folder it opens; that is not an altered kit.
    actual = {p.relative_to(kit).as_posix() for p in kit.rglob("*")
              if not p.is_dir() and p.name != ".DS_Store"}
    if actual != KIT_FILES | {"MANIFEST.json"}:
        raise ValueError("unexpected agent kit contents")
    for name, pin in files.items():
        path = kit / name
        # Only check for symlinks within the kit itself; parent directories (like /var/folders on
        # macOS) are often symlinked and that is not a kit defect.
        if path.is_symlink():
            raise ValueError("agent kit contains an alias")
        data = path.read_bytes()
        if len(data) != pin["bytes"] or hashlib.sha256(data).hexdigest() != pin["sha256"]:
            raise ValueError("agent kit checksum mismatch")
    version((kit / "VERSION").read_text().strip())
    publisher_config(json.loads((kit / "publisher.json").read_text()), allow_test=allow_test)
    return manifest


# --------------------------------------------------------------------------- which apps are here
def account_home() -> Path:
    """This account's own home - a fact about the Mac, not whatever `HOME` happens to say.

    `HOME` is something a test, or `sudo`, can point anywhere; `pwd` cannot. A home that is not
    this account's own is treated as isolated, which is also the rule the Hub's client applies to a
    scratch home, so the two agree about which apps are on the Mac in every situation either of
    them actually runs in.
    """
    try:
        import pwd
        return Path(pwd.getpwuid(os.getuid()).pw_dir)
    except (ImportError, KeyError, OSError):
        return Path.home()


def app_folders(home: Path) -> list[Path]:
    """Where an app bundle may live for this Mac.

    An isolated home never inventories `/Applications`: a test home must not see the real Mac's
    apps, and neither must a run whose home was pointed somewhere else deliberately.
    """
    if home != account_home():
        return [home / "Applications"]
    return [home / "Applications", Path("/Applications")]


def load_app_registry(path: Path) -> dict:
    """`apps.json` - the three apps this agent may manage, by bundle identifier."""
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    apps = raw["apps"] if isinstance(raw, dict) else None
    if not isinstance(apps, dict) or not apps:
        raise ValueError("apps config has no apps")
    for identity, entry in apps.items():
        if not isinstance(entry, dict) or set(entry) != {"app", "recipe"}:
            raise ValueError(f"apps config entry is not {{app, recipe}}: {identity}")
        if not isinstance(entry["app"], str) or not isinstance(entry["recipe"], str):
            raise ValueError(f"apps config entry is not text: {identity}")
    return apps


def app_config(home: Path, registry: dict) -> dict:
    """The `apps` block of the agent's config, built from the bundles found on THIS Mac.

    Same shape, same key order and same first-found-wins rule as the Hub's own reader.
    """
    # Automatic is on for a new Mac (owner, 2026-11-02); Story and Hub update themselves.
    apps = {"updater": {"bundlePath": "", "recipe": "updater", "automatic": True}}
    for root in app_folders(home):
        for bundle in sorted(root.glob("*.app")):
            try:
                info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
                identity = info["CFBundleIdentifier"]
                entry = registry.get(identity)
                if entry:
                    apps.setdefault(entry["app"], {"bundlePath": str(bundle.resolve()),
                                                   "recipe": entry["recipe"],
                                                   "automatic": entry["recipe"] not in ("story", "hub", "status"),
                                                   "bundleID": identity})
            except (OSError, ValueError, KeyError):
                continue
    return apps


# --------------------------------------------------------------------------- this Mac's name
def hub_data_dir(home: Path) -> Path | None:
    """Where the Hub installed on this Mac keeps its own settings, if there is one."""
    override = os.environ.get("STUDIOHUB_DATA_DIR")
    if override:
        return Path(override).expanduser()
    for folder in app_folders(home):
        # Both bundle names, matching the agent's own discovery: old installs keep the old name.
        for bundle in ("Studio Hub.app", "Hub Studio KH.app"):
            app = folder / bundle
            if app.is_dir():
                # The Hub's launcher root is the `voice/` folder inside its own bundle.
                return app / "Contents" / "Resources" / "voice"
    return None


def proposed_machine_id(home: Path) -> str:
    """The name this Mac should enrol under, before the owner is asked.

    On a Hub Mac it is that Hub's `controller_id`, because the Hub's own auto-install enrols under
    exactly that and the two paths must not disagree about who this Mac is. The Hub derives it from
    the hostname the first time and writes it down; read here when it has, derived identically when
    it has not. With no Hub on this Mac there is no such thing, so the name is the computer's.
    """
    override = os.environ.get("STUDIOHUB_CONTROLLER_ID")
    if override and ID_PATTERN.fullmatch(override.strip().lower()):
        return override.strip().lower()
    root = hub_data_dir(home)
    if root is not None:
        try:
            saved = json.loads((root / "controller_settings.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            saved = None
        if isinstance(saved, dict):
            saved_id = saved.get("controller_id")
            if isinstance(saved_id, str) and ID_PATTERN.fullmatch(saved_id.strip().lower()):
                return saved_id.strip().lower()
        return f"{safe_id(socket.gethostname().split('.', 1)[0])}-hub"[:100]
    return safe_id(socket.gethostname().split(".", 1)[0])


# --------------------------------------------------------------------------- the install itself
class Bootstrap:
    """Mirrors `khu_agent.Bootstrap`. Keep the two in step; `tests/test_khu_kit.py` compares the
    trees they produce for the same inputs byte for byte."""

    def __init__(self, kit: Path, home: Path, *, allow_test: bool = False, run=subprocess.run,
                 registry: dict | None = None):
        self.kit, self.home, self.allow_test, self.run = kit, home, allow_test, run
        self.registry = registry or {}
        self.root = home / "Library/KHUpdater"
        self.base = self.root / "base"

    #: The version the kit beside us states.
    def kit_version(self) -> str:
        return (self.kit / "VERSION").read_text().strip()

    def install(self) -> str:
        verify_kit(self.kit, allow_test=self.allow_test)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        if self.root.is_symlink() or self.base.is_symlink():
            raise ValueError("unsafe install path")
        with (self.root / "bootstrap.lock").open("a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.base.mkdir(exist_ok=True, mode=0o700)
            # Same lock used by the stub's rollback and the updater's signed self-update.
            with (self.base / "switch.lock").open("a+") as switch:
                fcntl.flock(switch, fcntl.LOCK_EX)
                wanted = (self.kit / "VERSION").read_text().strip()
                current = self.base / "current"
                if current.is_symlink():
                    installed = current.resolve(strict=True)
                    expected_versions = (self.base / "versions").resolve()
                    if installed.parent.parent != expected_versions or installed.name != "khu":
                        raise ValueError("unsafe current agent")
                    comparison = version(installed.parent.name)
                    wanted_v = version(wanted)
                    if comparison > wanted_v:
                        return "newer"
                    if comparison == wanted_v:
                        return "current"
                elif current.exists():
                    raise ValueError("current agent must be a version link")
                target = self.base / "versions" / wanted
                target.parent.mkdir(exist_ok=True, mode=0o700)
                if target.exists():
                    if (target / "khu").read_bytes() != (self.kit / "bin/khu").read_bytes():
                        raise ValueError("version already has different bytes")
                else:
                    stage = Path(tempfile.mkdtemp(prefix=".version-", dir=target.parent))
                    shutil.copyfile(self.kit / "bin/khu", stage / "khu")
                    (stage / "khu").chmod(0o755)
                    stage.rename(target)
                binaries = self.root / "bin"
                binaries.mkdir(exist_ok=True, mode=0o700)
                stub = binaries / "khu-stub"
                # The running supervisor is immutable. Agent upgrades only move version links.
                if not stub.exists():
                    shutil.copyfile(self.kit / "bin/khu-stub", stub)
                    stub.chmod(0o755)
                if current.is_symlink():
                    self._point("previous", os.readlink(current))
                self._point("current", f"versions/{wanted}/khu")
                return "installed"

    def _point(self, name: str, target: str) -> None:
        link = self.base / name
        fresh = self.base / (".link-" + secrets.token_hex(12))
        fresh.symlink_to(target)
        if link.is_symlink():
            bucket = self.base / "_trash" / secrets.token_hex(12)
            bucket.mkdir(parents=True, mode=0o700)
            (bucket / name).symlink_to(os.readlink(link))
        elif link.exists():
            raise ValueError("unsafe version link")
        os.replace(fresh, link)

    def enrolled(self) -> bool:
        """True when this Mac already has an enrolled agent - the state the other path leaves."""
        return (self.base / "config.json").is_file()

    def report(self) -> str:
        """One plain line about what is already here, read from what is on disk."""
        try:
            config = json.loads((self.base / "config.json").read_text(encoding="utf-8"))
            machine = config.get("machine")
        except (OSError, ValueError):
            machine = None
        link = self.base / "current"
        installed = link.resolve().parent.name if link.is_symlink() else None
        parts = [f"agent {installed}" if installed else "agent version unknown"]
        if machine:
            parts.append(f"enrolled as {machine}")
        return ", ".join(parts)

    def enrol(self, machine: str, code: str = "") -> None:
        config_file = self.base / "config.json"
        publisher = publisher_config(json.loads((self.kit / "publisher.json").read_text()),
                                     allow_test=self.allow_test)
        if config_file.exists():
            saved = json.loads(config_file.read_text())
            if (any(saved[k] != publisher[k] for k in ("feedURL", "publicKey"))
                    or saved["machine"] != machine):
                raise ValueError("installed agent has another authority or identity")
            return
        request_file = self.root / "enrol-request.json"
        if not request_file.exists():
            private_json(request_file, {"machine": machine, "nonce": secrets.token_hex(32)})
        request = json.loads(request_file.read_text())
        if request["machine"] != machine:
            raise ValueError("enrolment identity changed")
        # The pairing code the owner typed authorises this request; with none, only an open window
        # can. It is sent, never written to disk. The signed reply below is what this Mac trusts.
        body = json.dumps({**request, "code": code} if code else request).encode()
        signed = self._post(publisher["enrolURL"], body)
        raw = base64.b64decode(signed["reply"], validate=True)
        if not ed25519_verify(base64.b64decode(publisher["publicKey"]), raw,
                              base64.b64decode(signed["signature"], validate=True)):
            raise ValueError("publisher signature refused")
        payload = json.loads(raw)
        if (payload["machine"] != machine or payload["nonce"] != request["nonce"]
                or payload["feedURL"] != publisher["feedURL"]
                or payload["publicKey"] != publisher["publicKey"]
                or abs(time.time() - payload["issuedAt"]) > 300
                or not isinstance(payload["token"], str) or len(payload["token"]) < 32):
            raise ValueError("publisher reply refused")
        private_json(config_file, {**{k: publisher[k] for k in ("feedURL", "publicKey")},
                                  "machine": machine, "token": payload["token"],
                                  "stateDir": str(self.root / "state"), "stubBase": str(self.base),
                                  "apps": app_config(self.home, self.registry),
                                  "intervalMinutes": 5, "once": False})

    #: Set by the caller before `enrol`; the apps this agent may manage.
    registry: dict = {}

    def _post(self, url: str, body: bytes) -> dict:
        """POST and read a small JSON body, refusing a redirect, a proxy and an oversized reply."""
        opener = build_opener(_NoRedirects, ProxyHandler({}))
        request = Request(url, data=body, method="POST",
                          headers={"Content-Type": "application/json"})
        try:
            with opener.open(request, timeout=10) as response:
                status, content = response.status, response.read(16385)
        except HTTPError as error:
            # The publisher's own sentence: wrong code, locked, or a name already taken.
            reason = "".join(c for c in error.read(512).decode(errors="replace") if c.isprintable())
            raise ValueError(reason or "publisher has not authorised this Mac") from error
        except OSError as error:
            raise ValueError("the publisher could not be reached from this Mac") from error
        if status != 200 or len(content) > 16384:
            raise ValueError("publisher has not authorised this Mac")
        try:
            return json.loads(content.decode())
        except (ValueError, UnicodeDecodeError):
            raise ValueError("publisher reply was not JSON") from None

    def activate(self) -> bool:
        """Write the launchd job and load it. True when launchd already had it loaded.

        A failed `bootstrap` raises with launchctl's own words: the install is finished by then,
        and the caller keeps it rather than trashing it (the same rule as kh-updater's
        `install-agent.sh`).
        """
        if not (self.base / "config.json").is_file():
            raise ValueError("agent not enrolled")
        plist = self.home / "Library/LaunchAgents" / PLIST_NAME
        job = plistlib.loads((self.kit / "com.khupdater.agent.plist").read_bytes())
        job["ProgramArguments"] = [str(self.root / "bin/khu-stub"), "--base", str(self.base)]
        logfile = self.home / "Library/Logs/khupdater-agent.log"
        logfile.parent.mkdir(parents=True, exist_ok=True)
        job["StandardOutPath"] = job["StandardErrorPath"] = str(logfile)
        plist.parent.mkdir(parents=True, exist_ok=True)
        content = plistlib.dumps(job)
        if plist.exists() and plist.read_bytes() != content:
            raise ValueError("existing launch job differs; repair it explicitly")
        if not plist.exists():
            with plist.open("xb") as stream:
                stream.write(content)
            plist.chmod(0o600)
        domain = f"gui/{os.getuid()}"
        launchctl = os.environ.get("KH_UPDATER_LAUNCHCTL") or "/bin/launchctl"
        probe = self.run([launchctl, "print", domain + "/" + LAUNCHD_LABEL],
                         capture_output=True, timeout=10)
        if probe.returncode == 0:
            return True
        result = self.run([launchctl, "bootstrap", domain, str(plist)],
                          capture_output=True, timeout=15)
        if result.returncode:
            reason = (result.stderr or result.stdout or b"").decode(errors="replace").strip()
            raise StartFailed(reason or "launchctl refused without a message", plist)
        return False


class _NoRedirects(HTTPRedirectHandler):
    """A redirect is not an enrolment. The Hub's client refuses to follow them too."""

    def redirect_request(self, *args, **kwargs):
        return None


# --------------------------------------------------------------------------- Ed25519, verify only
# Ported from `components/hub/backend/ed25519.py` (the `verify` path and the arithmetic it needs).
_q = 2**255 - 19
_l = 2**252 + 27742317777372353535851937790883648493
_d = (-121665 * pow(121666, _q - 2, _q)) % _q
_I = pow(2, (_q - 1) // 4, _q)


def _recover_x(y: int, sign: int) -> int | None:
    u = (y * y - 1) % _q
    v = (_d * y * y + 1) % _q
    v3 = pow(v, 3, _q)
    v7 = pow(v, 7, _q)
    x = ((u * v3) % _q * pow((u * v7) % _q, (_q - 5) // 8, _q)) % _q
    if (v * x * x - u) % _q != 0:
        x = (x * _I) % _q
    if (v * x * x - u) % _q != 0:
        return None
    if x == 0 and sign:
        return None
    if (x & 1) != sign:
        x = _q - x
    return x


_By = (4 * pow(5, _q - 2, _q)) % _q
_Bx = _recover_x(_By, 0)
_B = (_Bx, _By, 1, (_Bx * _By) % _q)
_IDENTITY = (0, 1, 1, 0)


def _point_add(p, r):
    x1, y1, z1, t1 = p
    x2, y2, z2, t2 = r
    a = ((y1 - x1) * (y2 - x2)) % _q
    b = ((y1 + x1) * (y2 + x2)) % _q
    c = (2 * t1 * t2 * _d) % _q
    dd = (2 * z1 * z2) % _q
    e = (b - a) % _q
    f = (dd - c) % _q
    g = (dd + c) % _q
    h = (b + a) % _q
    return ((e * f) % _q, (g * h) % _q, (f * g) % _q, (e * h) % _q)


def _point_double(p):
    x1, y1, z1, _ = p
    a = (x1 * x1) % _q
    b = (y1 * y1) % _q
    c = (2 * z1 * z1) % _q
    g = (b - a) % _q
    h = (-a - b) % _q
    e = ((x1 + y1) * (x1 + y1) - a - b) % _q
    f = (g - c) % _q
    return ((e * f) % _q, (g * h) % _q, (f * g) % _q, (e * h) % _q)


def _scalar_mult(scalar: int, point):
    result = _IDENTITY
    addend = point
    while scalar > 0:
        if scalar & 1:
            result = _point_add(result, addend)
        addend = _point_double(addend)
        scalar >>= 1
    return result


def _encode_point(point) -> bytes:
    x, y, z, _ = point
    z_inv = pow(z, _q - 2, _q)
    x = (x * z_inv) % _q
    y = (y * z_inv) % _q
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def _decode_point(encoded: bytes):
    if len(encoded) != 32:
        return None
    raw = int.from_bytes(encoded, "little")
    sign = (raw >> 255) & 1
    y = raw & ((1 << 255) - 1)
    if y >= _q:
        return None
    x = _recover_x(y, sign)
    if x is None:
        return None
    return (x, y, 1, (x * y) % _q)


def ed25519_verify(public: bytes, message: bytes, signature: bytes) -> bool:
    """Strict RFC 8032 verification: non-canonical keys, R and S are all refused."""
    if len(public) != 32 or len(signature) != 64:
        return False
    point_a = _decode_point(public)
    if point_a is None:
        return False
    r_encoded = signature[:32]
    s = int.from_bytes(signature[32:], "little")
    if s >= _l:
        return False
    point_r = _decode_point(r_encoded)
    if point_r is None:
        return False
    k = int.from_bytes(hashlib.sha512(r_encoded + public + message).digest(), "little") % _l
    left = _scalar_mult(s, _B)
    right = _point_add(point_r, _scalar_mult(k, point_a))
    return _encode_point(left) == _encode_point(right)


# --------------------------------------------------------------------------- the run
def trash_partial_install(home: Path, plist: Path) -> Path | None:
    """Move what this run wrote out of the way, and say where. Nothing is ever deleted.

    None means there was nothing to move - a refusal that happened before the first file was
    written, which is a different outcome from a half-install that was tidied away.
    """
    root = home / "Library/KHUpdater"
    if not root.exists() and not plist.is_file():
        return None
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    trash = home / "Library" / "_trash"
    bucket = trash / f"khupdater-incomplete-{stamp}"
    # Two runs inside the same second must not land on each other: the second one gets its own
    # bucket rather than leaving a half-install in place because the name was taken.
    counter = 2
    while (bucket / "KHUpdater").exists() or (bucket / PLIST_NAME).exists():
        bucket = trash / f"khupdater-incomplete-{stamp}-{counter}"
        counter += 1
    bucket.mkdir(parents=True, exist_ok=True)
    if root.exists():
        shutil.move(str(root), str(bucket / "KHUpdater"))
    if plist.is_file():
        shutil.move(str(plist), str(bucket / PLIST_NAME))
    return bucket


def parse_arguments(argv: list[str]) -> dict:
    options = {"machine": None, "ask": True}
    index = 0
    while index < len(argv):
        item = argv[index]
        if item in ("--kit", "--home", "--apps", "--machine"):
            if index + 1 >= len(argv):
                raise SystemExit(f"{item} needs a value")
            options[item.lstrip("-")] = argv[index + 1]
            index += 2
            continue
        if item == "--allow-test":
            options["allow_test"] = True
        elif item == "--unattended":
            options["ask"] = False
        elif item in ("-h", "--help"):
            raise SystemExit(__doc__)
        else:
            raise SystemExit(f"unknown argument: {item}")
        index += 1
    if not options.get("kit") or not options.get("home"):
        raise SystemExit("usage: khu-install.py --kit DIR --home DIR [--apps FILE] "
                         "[--machine ID] [--unattended] [--allow-test]")
    return options


def main(argv: list[str]) -> int:
    options = parse_arguments(argv)
    here = Path(__file__).resolve().parent
    kit = Path(options["kit"]).expanduser().resolve()
    home = Path(options["home"]).expanduser().resolve()
    apps_file = Path(options.get("apps") or here / "apps.json").expanduser()
    allow_test = bool(options.get("allow_test"))

    print("  Studio Launcher KH")
    if kit.is_symlink() or not kit.is_dir() or not (kit / "publisher.json").is_file():
        print("  The agent kit is not beside this file, or it has no publisher.json.")
        print("  Nothing was installed. Use the kit's own 'Connect to Studio Launcher KH.command'.")
        return 1
    try:
        registry = load_app_registry(apps_file)
    except (OSError, ValueError, KeyError) as error:
        print(f"  The apps config could not be read ({error}). Nothing was installed.")
        return 1

    bootstrap = Bootstrap(kit, home, allow_test=allow_test, registry=registry)
    plist = home / "Library/LaunchAgents" / PLIST_NAME

    try:
        if bootstrap.enrolled():
            print(f"  Studio Launcher KH is already installed on this Mac ({bootstrap.report()}).")
            print("  Nothing was changed.")
            return 0

        machine = options.get("machine") or proposed_machine_id(home)
        if options["ask"]:
            shown = input(f"  Name for this Mac [{machine}]: ").strip().lower() or machine
            while not ID_PATTERN.fullmatch(shown):
                shown = input("  Lower-case letters, numbers, dots, dashes or underscores; "
                              "try again: ").strip().lower()
            machine = shown
        if not ID_PATTERN.fullmatch(machine):
            print(f"  '{machine}' is not a usable name for this Mac "
                  "(lower-case letters, numbers, dots, dashes or underscores).")
            print("  Nothing was installed.")
            return 2
        code = os.environ.get("KH_UPDATER_PAIRING_CODE", "")
        if options["ask"]:
            code = input("  Type the pairing code shown in Update Studio KH: ").strip()
    except (EOFError, KeyboardInterrupt):
        print("  Nothing was installed.")
        return 2

    try:
        state = bootstrap.install()
        print(f"  Agent files: {state} (agent {bootstrap.kit_version()})")
        bootstrap.enrol(machine, code)
        print(f"  Enrolled as {machine}.")
        loaded = bootstrap.activate()
    except StartFailed as failure:
        # The install is finished and stays: only the start failed, and one command retries it.
        # Trashing it here would make this Mac enrol a second time for a launchd hiccup.
        print(f"  Studio Launcher KH is installed but launchd did not start it: {failure}")
        print("  The install is kept; nothing was removed. Start it later with:")
        print(f"  launchctl bootstrap gui/{os.getuid()} {failure.plist}")
        return 1
    except (ValueError, KeyError, OSError) as error:
        where = trash_partial_install(home, plist)
        print(f"  Studio Launcher KH was NOT installed: {error}")
        if where is None:
            print("  Nothing was written.")
        else:
            print(f"  Anything this run wrote was moved to {where}.")
        print("  Fix that, then run this file again. "
              "The pairing code is in Update Studio KH on the Mac Studio.")
        return 1
    print("  Agent installed; launchd already has com.khupdater.agent loaded, so it was left alone."
          if loaded else "  Started at login: the launchd job is loaded.")
    print()
    print("  Studio Launcher KH will keep the apps on this Mac up to date. Its icon is in the menu bar.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
