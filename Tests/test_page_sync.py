#!/usr/bin/env python3
"""packaging/page-sync.sh against a fixture feed, a fake publisher host and a fake `gh`.

Nothing here reaches 1301, GitHub or the public internet: the feed and artifacts are served from a
loopback HTTP server, `ssh` is a script that runs the publisher's command in a fixture home, `gh` is
a script over a JSON store, and `khu` is a script that builds a mirror feed from the same fixture.

Each case starts from a fresh fixture and asserts on the script's own report lines, its exit status,
and the calls `gh` actually received — so "refused" means nothing was touched, not just that the
script said so.
"""
import base64
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "packaging" / "page-sync.sh"
WORK = Path(tempfile.mkdtemp(prefix="khu-page-sync-test-"))
passed = 0


def check(ok, what):
    global passed
    if not ok:
        raise AssertionError(what)
    passed += 1


def b64(text):
    return base64.b64encode(text if isinstance(text, bytes) else text.encode()).decode()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def entry(version, name, data, icon=None, icon_data=None):
    e = {"version": version, "file": name, "sha256": sha(data), "bytes": len(data), "kind": "dmg"}
    if icon:
        e["icon"] = icon
        e["iconSha256"] = sha(icon_data)
    return e


FAKE_GH = r'''#!/usr/bin/env python3
import base64, hashlib, json, os, sys
STATE, CALLS, PAGE = os.environ["FAKE_GH_STATE"], os.environ["FAKE_GH_CALLS"], os.environ["FAKE_GH_PAGE"]
args = sys.argv[1:]
open(CALLS, "a").write("\t".join(args) + "\n")

def rels():
    p = os.path.join(STATE, "releases.json")
    return json.load(open(p)) if os.path.exists(p) else []
def save(r):
    json.dump(r, open(os.path.join(STATE, "releases.json"), "w"))
def fail(msg):
    sys.stderr.write("gh: " + msg + "\n"); sys.exit(1)
def asset_of(path):
    data = open(path, "rb").read()
    if os.environ.get("FAKE_GH_CORRUPT"):
        return {"name": os.path.basename(path).replace(" ", "."), "size": len(data),
                "digest": "sha256:" + hashlib.sha256(b"corrupt").hexdigest()}
    return {"name": os.path.basename(path).replace(" ", "."), "size": len(data),
            "digest": "sha256:" + hashlib.sha256(data).hexdigest()}
def serve_asset(tag, path):
    # GitHub would serve the uploaded file at <tag>/<asset name>; the fixture serves the same shape
    # from its own origin so page-sync's post-run sweep checks real answers, not GitHub's.
    root = os.environ.get("FAKE_PUB_HOME")
    if not root: return
    d = os.path.join(root, tag); os.makedirs(d, exist_ok=True)
    open(os.path.join(d, os.path.basename(path).replace(" ", ".")), "wb").write(open(path, "rb").read())
def publish():
    src = os.path.join(STATE, "release.json")
    if not os.path.exists(src): return
    data = open(src, "rb").read()
    for side in (["canonical", "raw"] if not os.environ.get("FAKE_GH_STALE_RAW") else ["raw"]):
        d = os.path.join(PAGE, side); os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "release.json"), "wb").write(data)

if args[0] == "api":
    method, fields, path, i = "GET", {}, None, 1
    while i < len(args):
        if args[i] == "-X": method = args[i + 1]; i += 2
        elif args[i] == "-f":
            k, v = args[i + 1].split("=", 1); fields[k] = v; i += 2
        else: path = args[i]; i += 1
    repo_rest = "/".join(path.split("/")[3:]) if path.startswith("repos/") else path
    if repo_rest.startswith("releases?"):
        print(json.dumps(rels()))
    elif repo_rest.startswith("releases/tags/"):
        tag = repo_rest[len("releases/tags/"):]
        found = [r for r in rels() if r["tag_name"] == tag]
        if not found: fail("Not Found (HTTP 404)")
        print(json.dumps(found[0]))
    elif repo_rest.startswith("releases/") and method == "DELETE":
        rid = int(repo_rest[len("releases/"):])
        save([r for r in rels() if r["id"] != rid]); print("{}")
    elif repo_rest == "contents/release.json" and method == "GET":
        src = os.path.join(STATE, "release.json")
        if not os.path.exists(src): fail("Not Found (HTTP 404)")
        data = open(src, "rb").read()
        print(json.dumps({"sha": hashlib.sha1(data).hexdigest(), "content": base64.b64encode(data).decode(), "encoding": "base64"}))
    elif repo_rest == "contents/release.json" and method == "PUT":
        open(os.path.join(STATE, "release.json"), "wb").write(base64.b64decode(fields["content"]))
        publish(); print(json.dumps({"commit": {"sha": "f" * 40}}))
    else:
        fail("Not Found (HTTP 404)")
elif args[0] == "release" and args[1] == "create":
    tag, path = args[2], args[3]
    if any(r["tag_name"] == tag for r in rels()): fail("release already exists")
    rel = {"id": len(rels()) + 1, "tag_name": tag, "assets": [asset_of(path)]}
    save(rels() + [rel]); serve_asset(tag, path); print("https://example.invalid/" + tag)
elif args[0] == "release" and args[1] == "upload":
    tag, path = args[2], args[3]
    all_rels = rels()
    found = [r for r in all_rels if r["tag_name"] == tag]
    if not found: fail("Not Found (HTTP 404)")
    found[0]["assets"].append(asset_of(path)); save(all_rels); serve_asset(tag, path); print("uploaded")
else:
    fail("unsupported: " + " ".join(args))
'''

FAKE_SSH = '''#!/bin/bash
# The publisher host: the last argument is the command, run in the fixture home.
last=""
for a in "$@"; do last="$a"; done
HOME="$FAKE_PUB_HOME" exec /bin/bash -c "$last"
'''

FAKE_KHU = r'''#!/usr/bin/env python3
import base64, json, os, sys
a = sys.argv[1:]
if not a or a[0] != "mirror": sys.exit("fake khu: only mirror")
opts, i = {}, 1
while i < len(a):
    if a[i] == "--current-only": opts["current"] = True; i += 1
    else: opts[a[i].lstrip("-")] = a[i + 1]; i += 2
names = {}
for line in open(opts["names"]):
    f = line.rstrip("\n").split("\t")
    if len(f) == 5: names[(f[0], f[2])] = (f[1], f[3])
feed = json.loads(base64.b64decode(json.load(open(os.path.join(opts["feed"], "release.json")))["feed"]))
out, behind = {}, []
for app in opts["apps"].split(","):
    e = dict(feed["apps"][app])
    p = (feed.get("previous") or {}).get(app)
    if (app, e["file"]) not in names:
        # A page row behind the feed: the mirror keeps the newest version the page does carry.
        if not p or (app, p["file"]) not in names: sys.exit("fake khu: no row for " + app)
        e = dict(p); behind.append(app)
    tag, stored = names[(app, e["file"])]
    e["file"], e["url"] = stored, opts["base"] + "/" + tag + "/" + stored
    if e.get("icon"): e["icon"] = names[(app, e["icon"])][1]
    e.pop("delta", None)
    out[app] = e
for app in behind:
    print("behind: %s — the page has no row for the feed's version, so its newest page row is mirrored." % app)
body = {"schema": feed["schema"], "published_at": feed["published_at"], "apps": out}
if not opts.get("current"):
    prev = {}
    for app in opts["apps"].split(","):
        p = (feed.get("previous") or {}).get(app)
        if not p or app in behind or (app, p["file"]) not in names: continue
        q = dict(p); tag, stored = names[(app, p["file"])]
        q["file"], q["url"] = stored, opts["base"] + "/" + tag + "/" + stored
        if q.get("icon") and (app, q["icon"]) in names: q["icon"] = names[(app, q["icon"])][1]
        q.pop("delta", None)
        prev[app] = q
    if prev: body["previous"] = prev
if feed.get("network"): body["network"] = {"feedURLs": feed["network"].get("feedURLs", [])}
if os.environ.get("FAKE_KHU_DROP"):
    body.pop(os.environ["FAKE_KHU_DROP"], None)
data = json.dumps(body, sort_keys=True).encode()
open(opts["out"], "w").write(json.dumps({"feed": base64.b64encode(data).decode(),
                                         "signature": base64.b64encode(b"sig").decode()}))
if os.environ.get("FAKE_KHU_BUMP"):
    feed["published_at"] = "2026-11-20T09:09:00.000Z"
    open(os.path.join(opts["feed"], "release.json"), "w").write(json.dumps({"feed": base64.b64encode(json.dumps(feed).encode()).decode(),
                                              "signature": base64.b64encode(b"sig").decode()}))
'''


class Fixture:
    """One run's world: a publisher home, a page, and the loopback server over both."""

    def __init__(self, feed_doc, page_releases=None, artifacts=None):
        self.dir = Path(tempfile.mkdtemp(prefix="case-", dir=WORK))
        self.bin = self.dir / "bin"; self.bin.mkdir()
        self.pub = self.dir / "pub"; self.kh = self.pub / "Library" / "KHUpdater"
        self.state = self.dir / "state"; self.state.mkdir()
        self.page = self.pub / "page"; self.page.mkdir(parents=True)
        self.calls = self.dir / "calls.log"
        (self.kh / "feed" / "artifacts").mkdir(parents=True)
        (self.kh / "keys").mkdir()
        (self.kh / "keys" / "private.key").write_text("test key\n")
        (self.kh / "base").mkdir()
        self.write_exec(self.bin / "ssh", FAKE_SSH)
        self.write_exec(self.bin / "gh", FAKE_GH)
        self.write_exec(self.kh / "base" / "current", FAKE_KHU)
        self.feed_doc = feed_doc
        self.feed_path = self.kh / "feed" / "release.json"
        self.write_feed(feed_doc)
        for name, data in (artifacts or {}).items():
            (self.kh / "feed" / "artifacts" / name).write_bytes(data)
        json.dump(page_releases or [], open(self.state / "releases.json", "w"))
        # A page row that exists has a file behind it; serve each one, so the post-run sweep is
        # checking real answers for the rows this fixture says are already on the page.
        for rel in page_releases or []:
            d = self.pub / rel["tag_name"]; d.mkdir(parents=True, exist_ok=True)
            for a in rel.get("assets", []):
                (d / a["name"]).write_bytes(b"page-asset")
        self.httpd, self.port = self.serve()

    def write_exec(self, path, text):
        path.write_text(text); path.chmod(0o755)

    def write_feed(self, doc):
        self.feed_path.write_text(json.dumps({"feed": b64(json.dumps(doc)), "signature": b64("sig")}))

    def serve(self):
        class Quiet(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *a): pass
        handler = functools.partial(Quiet, directory=str(self.pub))
        httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        with socket.socket() as s:
            return httpd, httpd.server_address[1]

    def url(self, tail):
        return f"http://127.0.0.1:{self.port}/{tail}"

    def run(self, args, extra_env=None):
        env = {**os.environ,
               "PATH": f"{self.bin}:{os.environ['PATH']}",
               "FAKE_GH_STATE": str(self.state), "FAKE_GH_CALLS": str(self.calls),
               "FAKE_GH_PAGE": str(self.page), "FAKE_PUB_HOME": str(self.pub),
               "KHU_FEED_URL": self.url("Library/KHUpdater/feed/release.json"),
               "KHU_PAGES_URL": self.url("page/canonical/release.json"),
               "KHU_RAW_URL": self.url("page/raw/release.json"),
               "KHU_PUBLIC_WAIT": "5", "KHU_RELEASE_HOST": "fake-1301",
               # The page's downloads hang off its own origin, which the fixture serves, so the
               # post-run sweep answers for real and never reaches GitHub.
               "KHU_MIRROR_BASE": self.url("").rstrip("/"),
               "KHU_RELEASE_KEY": str(self.dir / "key"), "KHU_PUBLIC_REPO": "theng12/kh-releases"}
        env.update(extra_env or {})
        result = subprocess.run([str(SCRIPT), *args], capture_output=True, text=True, env=env)
        return result

    def gh_calls(self):
        return self.calls.read_text().splitlines() if self.calls.exists() else []

    def publishes(self, name):
        return [line for line in self.gh_calls() if name in line]

    def committed(self):
        path = self.state / "release.json"
        return json.loads(base64.b64decode(json.loads(path.read_text())["feed"])) if path.exists() else None

    def close(self):
        self.httpd.shutdown()


ALPHA_DMG = b"alpha installer bytes" * 40
ALPHA_ICON = b"alpha icon png"
BETA_DMG = b"beta installer bytes" * 30
BETA_ICON = b"beta icon png"
WHEN = "2026-11-19T16:48:53.757Z"


def two_apps(alpha_icon=True):
    alpha = entry("1.0.1", "aaa-Alpha Studio KH-1.0.1.dmg", ALPHA_DMG,
                  "aaa-icon.png" if alpha_icon else None, ALPHA_ICON)
    beta = entry("2.0.0", "bbb-Beta Studio KH-2.0.0.dmg", BETA_DMG, "bbb-icon.png", BETA_ICON)
    return {"schema": 1, "published_at": WHEN, "apps": {"alpha": alpha, "beta": beta}}


def beta_on_page(alpha_previous=False):
    rows = [{"id": 9, "tag_name": "beta-2.0.0", "assets": [
        {"name": "bbb-Beta.Studio.KH-2.0.0.dmg", "size": len(BETA_DMG), "digest": "sha256:" + sha(BETA_DMG)},
        {"name": "bbb-icon.png", "size": len(BETA_ICON), "digest": "sha256:" + sha(BETA_ICON)}]}]
    if alpha_previous:
        rows.append({"id": 8, "tag_name": "alpha-1.0.0", "assets": [
            {"name": "aaa-Alpha.Studio.KH-1.0.0.dmg", "size": 10, "digest": "sha256:" + "0" * 64}]})
    return rows


def with_previous():
    doc = two_apps()
    doc["previous"] = {"alpha": {"version": "1.0.0", "file": "aaa-Alpha Studio KH-1.0.0.dmg",
                                 "sha256": "0" * 64, "bytes": 10}}
    return doc


def artifacts():
    return {"aaa-Alpha Studio KH-1.0.1.dmg": ALPHA_DMG, "aaa-icon.png": ALPHA_ICON,
            "bbb-Beta Studio KH-2.0.0.dmg": BETA_DMG, "bbb-icon.png": BETA_ICON}


def step_lines(out, subject):
    """(step number, rest of the line) for one subject's report lines."""
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[0] == subject:
            rows.append((int(parts[1]), parts[2]))
    return rows


# ---------------------------------------------------------------- the cases
def case_happy_path_and_stored_name():
    fx = Fixture(two_apps(), beta_on_page(), artifacts())
    try:
        r = fx.run(["--app", "alpha", "--accepted", sha(ALPHA_DMG)])
        out = r.stdout
        check(r.returncode == 0, f"happy path must exit 0, got {r.returncode}\n{out}\n{r.stderr}")
        steps = [n for n, _ in step_lines(out, "alpha")] + [n for n, _ in step_lines(out, "page")]
        check(sorted(set(steps)) == list(range(1, 10)), f"a line for every step (got {steps})\n{out}")
        # GitHub's rewrite is carried by the mirror, not the feed's name.
        doc = fx.committed()
        check(doc["apps"]["alpha"]["file"] == "aaa-Alpha.Studio.KH-1.0.1.dmg",
              "the mirror must carry the name GitHub stored")
        check(doc["apps"]["alpha"]["url"] == fx.url("alpha-1.0.1/aaa-Alpha.Studio.KH-1.0.1.dmg"),
              "the mirror must name the page's own address")
        check(doc["apps"]["alpha"]["sha256"] == sha(ALPHA_DMG), "the mirror keeps the feed's digest")
        check(set(doc) == {"schema", "published_at", "apps"}, f"no network block, no previous: {sorted(doc)}")
        check(doc["published_at"] == WHEN, "the mirror carries the feed's published_at")
        check("beta" in doc["apps"], "an app not synced here is still carried from the page")
        check("stored it under this name" in out, "the rewrite must be reported, not silent")
        check("both public addresses serve" in out, "both addresses must be read back")
        check("0 refused" in out, "the summary must count refusals")
    finally:
        fx.close()


def case_digest_mismatch_retires_nothing():
    fx = Fixture(with_previous(), beta_on_page(alpha_previous=True), artifacts())
    try:
        r = fx.run(["--app", "alpha", "--accepted", sha(ALPHA_DMG)], {"FAKE_GH_CORRUPT": "1"})
        check(r.returncode == 5, f"a stored digest that differs must refuse (got {r.returncode})")
        check("carries no asset with digest" in r.stdout or "already holds" in r.stdout,
              f"the refusal must say what differed\n{r.stdout}")
        check(fx.publishes("DELETE") == [],
              f"nothing may be retired when the digest does not match: {fx.publishes('DELETE')}")
        check(fx.publishes("PUT") == [],
              f"nothing may be committed when the digest does not match: {fx.publishes('PUT')}")
        check("earlier action(s) stand and the mirror was not rebuilt" in r.stdout,
              f"the refusal must say what already happened upstream\n{r.stdout}")
    finally:
        fx.close()


def case_keeps_previous_and_mirrors_it():
    fx = Fixture(with_previous(), beta_on_page(alpha_previous=True), artifacts())
    try:
        r = fx.run(["--app", "alpha", "--accepted", sha(ALPHA_DMG)])
        check(r.returncode == 0, f"a page with a previous row must sync\n{r.stdout}\n{r.stderr}")
        check(fx.publishes("DELETE") == [], f"the previous row is never retired: {fx.publishes('DELETE')}")
        check("alpha          7 previous kept" in r.stdout or "alpha-1.0.0 is on the page with the feed's bytes — kept" in r.stdout,
              f"the kept row must be reported\n{r.stdout}")
        doc = fx.committed()
        check(doc.get("previous", {}).get("alpha", {}).get("version") == "1.0.0",
              f"the mirror must carry the feed's previous entry: {sorted(doc)}")
        check(doc["previous"]["alpha"]["file"] == "aaa-Alpha.Studio.KH-1.0.0.dmg",
              f"the previous entry names the page's own asset: {doc['previous']['alpha']}")
    finally:
        fx.close()


def case_mirror_that_drops_previous_refuses():
    fx = Fixture(with_previous(), beta_on_page(alpha_previous=True), artifacts())
    try:
        r = fx.run(["--app", "alpha", "--accepted", sha(ALPHA_DMG)], extra_env={"FAKE_KHU_DROP": "previous"})
        check(r.returncode == 5, f"a mirror that drops previous must refuse (got {r.returncode})\n{r.stdout}")
        check("dropped the feed's previous entry for alpha" in r.stdout,
              f"it must name the key and the app\n{r.stdout}")
    finally:
        fx.close()


def with_network():
    doc = with_previous()
    doc["network"] = {"feedURLs": ["https://theng12.github.io/kh-releases/release.json"],
                      "controller": {"from": "http://100.75.85.116:8790/release.json",
                                     "to": "http://100.82.91.102:8790/release.json"}}
    return doc


def case_mirror_keeps_public_network_and_refuses_a_drop():
    fx = Fixture(with_network(), beta_on_page(alpha_previous=True), artifacts())
    try:
        r = fx.run(["--app", "alpha", "--accepted", sha(ALPHA_DMG)])
        check(r.returncode == 0, f"a feed with a network block must mirror\n{r.stdout}\n{r.stderr}")
        doc = fx.committed()
        check(doc.get("network") == {"feedURLs": ["https://theng12.github.io/kh-releases/release.json"]},
              f"the mirror keeps the public addresses and no controller: {doc.get('network')}")
        check("controller withheld" in r.stdout, f"the withholding must be said, not silent\n{r.stdout}")
    finally:
        fx.close()
    fx = Fixture(with_network(), beta_on_page(alpha_previous=True), artifacts())
    try:
        r = fx.run(["--app", "alpha", "--accepted", sha(ALPHA_DMG)], extra_env={"FAKE_KHU_DROP": "network"})
        check(r.returncode == 5, f"a mirror that drops network must refuse (got {r.returncode})\n{r.stdout}")
        check("dropped the feed's network addresses" in r.stdout, f"it must name the key\n{r.stdout}")
    finally:
        fx.close()


def case_previous_missing_on_the_page_does_not_freeze_the_run():
    # Beta's feed has a previous release the page has never carried. Syncing alpha must build and
    # say so once; requiring a previous row for every app froze the whole page on 2026-11-22.
    doc = with_previous()
    doc["previous"]["beta"] = {"version": "1.9.0", "file": "bbb-Beta Studio KH-1.9.0.dmg",
                               "sha256": "1" * 64, "bytes": 11}
    fx = Fixture(doc, beta_on_page(alpha_previous=True), artifacts())
    try:
        r = fx.run(["--app", "alpha", "--accepted", sha(ALPHA_DMG)])
        check(r.returncode == 0, f"a missing previous row must not fail the run\n{r.stdout}\n{r.stderr}")
        check("previous not on the page" in r.stdout and "beta" in r.stdout,
              f"the gap must be named once\n{r.stdout}")
        committed = fx.committed()
        check("beta" not in (committed.get("previous") or {}),
              f"beta is carried current only: {(committed.get('previous') or {}).keys()}")
        check("alpha" in (committed.get("previous") or {}), "alpha's previous row is carried")
    finally:
        fx.close()


def case_behind_app_on_another_row_does_not_fail_the_run():
    # beta's page row is a release behind the feed; alpha is current. Syncing alpha must build and
    # must not be stopped by beta — one behind app freezes nothing.
    doc = two_apps()
    doc["apps"]["beta"] = entry("2.0.1", "bbb-Beta Studio KH-2.0.1.dmg", BETA_DMG, "bbb-icon.png", BETA_ICON)
    doc["previous"] = {"beta": {"version": "2.0.0", "file": "bbb-Beta Studio KH-2.0.0.dmg",
                                "sha256": sha(BETA_DMG), "bytes": len(BETA_DMG)}}
    fx = Fixture(doc, beta_on_page(alpha_previous=True), artifacts())
    try:
        r = fx.run(["--app", "alpha", "--accepted", sha(ALPHA_DMG)])
        check(r.returncode == 0, f"another app's behind row must not fail this run\n{r.stdout}\n{r.stderr}")
        check("kept as they are: beta" in r.stdout, f"the gap must be named once\n{r.stdout}")
        doc_committed = fx.committed()
        check(doc_committed["apps"]["beta"]["version"] == "2.0.0",
              f"beta keeps the page's newest row: {doc_committed['apps']['beta']}")
    finally:
        fx.close()


def case_all_mode_refuses_an_app_it_cannot_carry():
    # Asking for every app means every app must reach the page. A run asked for an app the page
    # cannot be given fails naming it — here at its artifact, before the mirror, which is earlier
    # and more precise than the mirror's own check. A single-app run is never stopped by another
    # app's row (the case above), which is the failure this change exists to remove.
    doc = two_apps()
    doc["apps"]["beta"] = entry("2.0.1", "bbb-Beta Studio KH-2.0.1.dmg", b"beta 2.0.1 bytes",
                                "bbb-icon.png", BETA_ICON)
    fx = Fixture(doc, beta_on_page(alpha_previous=True), artifacts())
    try:
        accepted = fx.dir / "accepted.tsv"
        accepted.write_text(f"alpha\t{sha(ALPHA_DMG)}\nbeta\t{sha(b'beta 2.0.1 bytes')}\n")
        r = fx.run(["--all", "--accepted-file", str(accepted)])
        check(r.returncode == 5, f"an app the page cannot be given must refuse (got {r.returncode})\n{r.stdout}")
        check("beta stopped at step 10" in r.stdout or "beta" in r.stdout,
              f"it must name the app that could not be carried\n{r.stdout}")
    finally:
        fx.close()


def case_artifact_hash_mismatch_refuses_before_upload():
    fx = Fixture(two_apps(), beta_on_page(), dict(artifacts(), **{"aaa-Alpha Studio KH-1.0.1.dmg": b"wrong bytes"}))
    try:
        r = fx.run(["--app", "alpha", "--accepted", sha(ALPHA_DMG)])
        check(r.returncode == 5, f"a local file that is not the feed's build must refuse (got {r.returncode})")
        check("the feed says" in r.stdout, f"it must name both digests\n{r.stdout}")
        check(fx.gh_calls() == [], f"nothing may be uploaded: {fx.gh_calls()}")
    finally:
        fx.close()


def case_unaccepted_sha_touches_nothing():
    fx = Fixture(two_apps(), beta_on_page(), artifacts())
    try:
        r = fx.run(["--app", "alpha", "--accepted", "deadbeef" * 8])
        check(r.returncode == 5, f"an unaccepted sha must refuse (got {r.returncode})")
        check(fx.gh_calls() == [], f"nothing may reach GitHub before the acceptance passes: {fx.gh_calls()}")
        check("not the one that passed" in r.stdout, f"the refusal must say why\n{r.stdout}")
        check(fx.committed() is None, "nothing may be committed")
    finally:
        fx.close()


def case_mirror_staleness_refuses():
    fx = Fixture(two_apps(), beta_on_page(), artifacts())
    try:
        r = fx.run(["--app", "alpha", "--accepted", sha(ALPHA_DMG)], {"FAKE_KHU_BUMP": "1"})
        check(r.returncode == 5, f"a feed that moved under the mirror must refuse (got {r.returncode})")
        check("the feed moved while the mirror was being built" in r.stdout, f"say it plainly\n{r.stdout}")
        check(fx.committed() is None, "nothing may be committed after the feed moved")
    finally:
        fx.close()


def case_second_run_changes_nothing():
    fx = Fixture(two_apps(), beta_on_page(), artifacts())
    try:
        first = fx.run(["--app", "alpha", "--accepted", sha(ALPHA_DMG)])
        check(first.returncode == 0, f"first run must pass\n{first.stdout}\n{first.stderr}")
        before = len(fx.gh_calls())
        second = fx.run(["--app", "alpha", "--accepted", sha(ALPHA_DMG)])
        check(second.returncode == 0, f"second run must pass\n{second.stdout}\n{second.stderr}")
        later = fx.gh_calls()[before:]
        mutating = [c for c in later if "\tcreate\t" in "\t" + c or "\tupload\t" in "\t" + c
                    or "DELETE" in c or "PUT" in c]
        check(mutating == [], f"a second run must change nothing on the page: {mutating}")
        check("already carries the feed's bytes" in second.stdout, "it must say the row is already right")
        check("no commit made" in second.stdout, "it must say the commit would be identical")
        check("0 refused" in second.stdout, "a quiet second run is still a full report")
    finally:
        fx.close()


def case_app_without_icon_skips():
    fx = Fixture(two_apps(alpha_icon=False), beta_on_page(), artifacts())
    try:
        r = fx.run(["--app", "alpha", "--accepted", sha(ALPHA_DMG)])
        check(r.returncode == 0, f"an app with no icon is not a failure\n{r.stdout}\n{r.stderr}")
        check("skipped: the feed names no icon for alpha" in r.stdout, "the skip must carry its reason")
        check("skipped, 0 refused" in r.stdout, "the summary must count the skip")
    finally:
        fx.close()


def case_all_mode_syncs_every_listed_app():
    fx = Fixture(two_apps(), [], artifacts())
    try:
        accepted = fx.dir / "accepted.tsv"
        accepted.write_text(f"alpha\t{sha(ALPHA_DMG)}\nbeta\t{sha(BETA_DMG)}\n")
        r = fx.run(["--all", "--accepted-file", str(accepted)])
        check(r.returncode == 0, f"both apps must sync\n{r.stdout}\n{r.stderr}")
        doc = fx.committed()
        check(sorted(doc["apps"]) == ["alpha", "beta"], f"both rows must reach the mirror: {sorted(doc['apps'])}")
        created = [c for c in fx.gh_calls() if "\tcreate\t" in "\t" + c]
        check(len(created) == 2, f"one release per app: {created}")
        check("both public addresses serve" in r.stdout, "one mirror and one commit for the whole page")
        check(r.stdout.count("built on fake-1301") == 1, "the mirror is rebuilt once, not once per app")
    finally:
        fx.close()


def case_dry_run_performs_nothing():
    fx = Fixture(two_apps(), beta_on_page(), artifacts())
    try:
        r = fx.run(["--app", "alpha", "--accepted", sha(ALPHA_DMG), "--dry-run"])
        check(r.returncode == 0, f"a dry run must exit 0\n{r.stdout}\n{r.stderr}")
        check("would create release alpha-1.0.1" in r.stdout, f"the dry run must print the plan\n{r.stdout}")
        mutating = [c for c in fx.gh_calls() if "\tcreate\t" in "\t" + c or "\tupload\t" in "\t" + c
                    or "DELETE" in c or "PUT" in c]
        check(mutating == [], f"a dry run must perform nothing: {mutating}")
        check(fx.committed() is None, "a dry run must not commit")
        check("nothing performed" in r.stdout, "it must say so")
    finally:
        fx.close()


def case_address_reports_not_served():
    fx = Fixture(two_apps(), beta_on_page(), artifacts())
    try:
        r = fx.run(["--app", "alpha", "--accepted", sha(ALPHA_DMG)], {"FAKE_GH_STALE_RAW": "1"})
        check(r.returncode == 6, f"one address behind is committed-but-unserved, not a pass (got {r.returncode})")
        check("NOT YET SERVED" in r.stdout, f"it must say which address lagged\n{r.stdout}")
        check(fx.committed() is not None, "the commit itself stands and is reported")
    finally:
        fx.close()


def case_usage_refusals():
    fx = Fixture(two_apps(), beta_on_page(), artifacts())
    try:
        r = fx.run(["--app", "alpha", "--accepted", sha(ALPHA_DMG)], {"KHU_PUBLIC_REPO": ""})
        check(r.returncode == 2, f"a missing repo is a usage error (got {r.returncode})")
        check("not built in" in r.stderr, f"it must say the repo is not built in\n{r.stderr}")
        r = fx.run(["--all", "--accepted-file", str(fx.dir / "nope.tsv")])
        check(r.returncode == 2, f"a missing acceptance file is a usage error (got {r.returncode})")
    finally:
        fx.close()


def case_feed_app_without_a_page_row_is_not_mirrored():
    # The live feed carries apps the page has no row for (Hub, the updater helper). The mirror
    # cannot name them, so step 8 must compare only the apps it carries — not the whole feed.
    GAMMA_DMG = b"gamma installer bytes" * 20
    doc = two_apps()
    doc["apps"]["gamma"] = entry("3.0.0", "ggg-Gamma Studio KH-3.0.0.dmg", GAMMA_DMG)
    fx = Fixture(doc, beta_on_page(), dict(artifacts(), **{"ggg-Gamma Studio KH-3.0.0.dmg": GAMMA_DMG}))
    try:
        r = fx.run(["--app", "alpha", "--accepted", sha(ALPHA_DMG)])
        check(r.returncode == 0,
              f"an app the page does not carry must not stop the mirror\n{r.stdout}\n{r.stderr}")
        doc = fx.committed()
        check(sorted(doc["apps"]) == ["alpha", "beta"],
              f"only the apps the page carries reach the mirror: {sorted(doc['apps'])}")
        check("gamma" not in doc["apps"], "a feed-only app is not named by the public copy")
    finally:
        fx.close()


def case_bundle_id_naming_the_owner_is_not_a_leak():
    # com.terranash.* is the app's bundle identifier, present inside every copy; it is not an
    # address. The private-host scan must not refuse the real feed over it.
    doc = two_apps()
    doc["apps"]["alpha"]["bundleID"] = "com.terranash.alphastudiekh"
    fx = Fixture(doc, beta_on_page(), artifacts())
    try:
        r = fx.run(["--app", "alpha", "--accepted", sha(ALPHA_DMG)])
        check(r.returncode == 0, f"a bundle id is not a private host\n{r.stdout}\n{r.stderr}")
        check(fx.committed()["apps"]["alpha"]["bundleID"] == "com.terranash.alphastudiekh",
              "the mirror keeps the app's bundle id")
    finally:
        fx.close()


CASES = [case_happy_path_and_stored_name, case_digest_mismatch_retires_nothing,
         case_keeps_previous_and_mirrors_it, case_mirror_that_drops_previous_refuses,
         case_mirror_keeps_public_network_and_refuses_a_drop,
         case_previous_missing_on_the_page_does_not_freeze_the_run,
         case_behind_app_on_another_row_does_not_fail_the_run, case_all_mode_refuses_an_app_it_cannot_carry,
         case_artifact_hash_mismatch_refuses_before_upload,
         case_unaccepted_sha_touches_nothing, case_mirror_staleness_refuses,
         case_second_run_changes_nothing, case_app_without_icon_skips,
         case_all_mode_syncs_every_listed_app,
         case_dry_run_performs_nothing, case_address_reports_not_served,
         case_feed_app_without_a_page_row_is_not_mirrored,
         case_bundle_id_naming_the_owner_is_not_a_leak,
         case_usage_refusals]

if __name__ == "__main__":
    failed = 0
    for case in CASES:
        try:
            case()
            print(f"PASS {case.__name__}")
        except AssertionError as error:
            failed += 1
            print(f"FAIL {case.__name__}: {error}")
    shutil.rmtree(WORK, ignore_errors=True)
    if failed:
        print(f"{failed} of {len(CASES)} cases failed")
        sys.exit(1)
    print(f"ALL PAGE-SYNC TESTS PASS ({passed} checks, {len(CASES)} cases)")
