#!/usr/bin/env python3
"""Notarize build/MenuSearch.app and package the public release: a ZIP (what the in-app upgrade downloads) and a DMG.

    python3 scripts/release.py

Order: check that build/MenuSearch.app is the build named by perf/build-receipt.json, made from the current clean
commit and signed with a Developer ID under the hardened runtime → notarize and staple the app → ZIP the stapled
app → build, sign, notarize and staple the DMG → check both with Gatekeeper and re-read the DMG's contents → write
build/release/{release.json,SHA256SUMS} and perf/release.json. It never rebuilds, installs, tags or uploads.

Notary credentials: NOTARY_KEYCHAIN_PROFILE (a notarytool keychain profile), or ASC_KEY_ID + ASC_ISSUER_ID with the
key at ~/.appstoreconnect/private_keys/AuthKey_<id>.p8. Nothing secret is printed or stored.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "build/MenuSearch.app"
OUT = ROOT / "build/release"
EXECUTABLE = "Contents/MacOS/MenuSearch"
REPOSITORY = "zengtianli/MenuSearch"


def run(*args, capture=False):
    return subprocess.run([str(a) for a in args], check=True, capture_output=capture, text=True)


def sha(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def provenance():
    """Read-only, before any upload: the app on disk is the receipted build of the committed source."""
    receipt = json.loads((ROOT / "perf/build-receipt.json").read_text())
    artifact, source = receipt["artifact"], receipt["source"]
    info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
    if (artifact["bundle_id"], artifact["version"], str(artifact["build"])) != (
            info["CFBundleIdentifier"], info["CFBundleShortVersionString"], str(info["CFBundleVersion"])):
        raise SystemExit("build/MenuSearch.app is not the build named by perf/build-receipt.json.")
    if sha(APP / EXECUTABLE) != artifact["sha256"]:
        raise SystemExit("The executable differs from the build receipt; build again through the receipt step.")
    git = lambda *args: subprocess.run(["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True).stdout.strip()
    head = git("rev-parse", "--verify", "HEAD^{commit}")
    if source.get("commit") != head or source.get("dirty") is not False:
        raise SystemExit("The receipt must name the current, clean commit; commit the source and build again.")
    if git("status", "--porcelain", "--", *[f":(glob){pattern}" for pattern in source["input_globs"]]):
        raise SystemExit("Source files changed after the build.")
    signature = run("codesign", "-dv", "--verbose=4", APP, capture=True).stderr
    authority = next((line.removeprefix("Authority=") for line in signature.splitlines()
                      if line.startswith("Authority=Developer ID Application:")), None)
    if not authority or "(runtime)" not in signature:
        raise SystemExit("A Developer ID signature with the hardened runtime is required.")
    return info, authority, {"source_commit": head, "source_sha256": source["sha256"], "executable_sha256": artifact["sha256"]}


def credentials():
    if os.environ.get("NOTARY_KEYCHAIN_PROFILE"):
        return ["--keychain-profile", os.environ["NOTARY_KEYCHAIN_PROFILE"]]
    kid, issuer = os.environ.get("ASC_KEY_ID"), os.environ.get("ASC_ISSUER_ID")
    if not (kid and issuer):
        helper = Path.home() / "Dev/tools/dev/lib/tools/macapp/ios"  # the maintainer's own key lookup, when present
        if not (helper / "asc.py").is_file():
            raise SystemExit("Set NOTARY_KEYCHAIN_PROFILE, or ASC_KEY_ID and ASC_ISSUER_ID.")
        sys.path.insert(0, str(helper))
        import asc
        kid, issuer = asc._personal_env("ASC_KEY_ID"), asc._personal_env("ASC_ISSUER_ID")
    key = Path.home() / ".appstoreconnect/private_keys" / f"AuthKey_{kid}.p8"
    if not key.is_file():
        raise SystemExit("The notary API key file is missing.")
    return ["--key", str(key), "--key-id", kid, "--issuer", issuer]


def notarize(payload, auth):
    result = json.loads(run("xcrun", "notarytool", "submit", payload, *auth, "--wait", "--timeout", "20m",
                            "--output-format", "json", capture=True).stdout)
    print(f"notarization {result.get('id')}: {result.get('status')}", flush=True)
    if result.get("status") != "Accepted":
        log = subprocess.run(["xcrun", "notarytool", "log", result.get("id", ""), *auth], capture_output=True, text=True).stdout
        raise SystemExit("Notarization was not accepted:\n" + log[-4000:])
    return result["id"]


def asset(path, version):
    return {"filename": path.name, "sha256": sha(path), "bytes": path.stat().st_size,
            "download_url": f"https://github.com/{REPOSITORY}/releases/download/v{version}/{path.name}"}


def main():
    if len(sys.argv) != 1:
        raise SystemExit(__doc__)
    info, authority, record = provenance()
    version, build = info["CFBundleShortVersionString"], str(info["CFBundleVersion"])
    auth = credentials()
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    archive, image = OUT / f"MenuSearch-{version}-arm64.zip", OUT / f"MenuSearch-{version}-arm64.dmg"
    with tempfile.TemporaryDirectory(prefix="menusearch-release.") as temp:
        temp = Path(temp)
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", APP, temp / "upload.zip")
        app_id = notarize(temp / "upload.zip", auth)
        run("xcrun", "stapler", "staple", APP)
        run("xcrun", "stapler", "validate", APP)
        run("spctl", "--assess", "--type", "execute", "--verbose=2", APP)
        if sha(APP / EXECUTABLE) != record["executable_sha256"]:
            raise SystemExit("Stapling changed the executable.")
        # Zipped after stapling, so the downloaded app passes Gatekeeper without asking Apple.
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", APP, archive)
        stage = temp / "stage"
        stage.mkdir()
        run("ditto", APP, stage / "MenuSearch.app")
        (stage / "Applications").symlink_to("/Applications")
        run("hdiutil", "create", "-quiet", "-volname", "MenuSearch", "-srcfolder", stage, "-format", "UDZO", image)
        run("codesign", "--force", "--sign", authority, "--timestamp", image)
        image_id = notarize(image, auth)
        run("xcrun", "stapler", "staple", image)
        run("xcrun", "stapler", "validate", image)
        run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", image)
        # Read both packages back the way a downloader gets them.
        run("ditto", "-x", "-k", archive, temp / "unzipped")
        mount = temp / "mount"
        mount.mkdir()
        run("hdiutil", "attach", "-quiet", "-readonly", "-nobrowse", "-mountpoint", mount, image)
        try:
            for copy in (temp / "unzipped/MenuSearch.app", mount / "MenuSearch.app"):
                run("codesign", "--verify", "--deep", "--strict", copy)
                run("xcrun", "stapler", "validate", copy)
                run("spctl", "--assess", "--type", "execute", copy)
                if sha(copy / EXECUTABLE) != record["executable_sha256"]:
                    raise SystemExit(f"{copy} holds a different executable.")
        finally:
            run("hdiutil", "detach", "-quiet", mount)
    record = {"version": version, "build": build, **asset(archive, version), "notarized": True,
              "notarization_id": app_id, "minimum_macos": info["LSMinimumSystemVersion"], "architecture": "arm64",
              "signing": "Developer ID Application with hardened runtime",
              "dmg": {**asset(image, version), "notarization_id": image_id},
              **record, "packaged_at": datetime.now(timezone.utc).isoformat(timespec="seconds")}
    text = json.dumps(record, indent=2) + "\n"
    (OUT / "release.json").write_text(text)
    (OUT / "SHA256SUMS").write_text("".join(f"{item['sha256']}  {item['filename']}\n" for item in (record, record["dmg"])))
    (ROOT / "perf/release.json").write_text(text)
    print(text)


if __name__ == "__main__":
    main()
