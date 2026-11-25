#!/usr/bin/env python3
"""Writes the AltStore / SideStore source for the iPhone and iPad app, or with `tvos` last, the
AltStore-format source for the Apple TV app, which tvOS sideloaders (ATVLoadly, FlareStore) read.

    scripts/altstore-source.py RELEASES.json OWNER/REPO TAG IPA OUT.json [tvos]

RELEASES.json is `gh api repos/OWNER/REPO/releases --paginate` (a list, or lists one after another).
The source lists every published release from v0.2.10 on that has AIOStreams.ipa, newest first:
earlier IPAs all said 0.2.0 inside, which AltStore would refuse as not the version it was told.
TAG's IPA is the file at IPA, whose size and SHA-256 are read from it. The workflow uploads OUT to
each release, so https://github.com/OWNER/REPO/releases/latest/download/altstore.json always names
the newest. Apple TV isn't listed: AltStore and SideStore install on iPhone and iPad only.
"""

import hashlib
import json
import os
import re
import sys

FIRST = (0, 2, 7)
MIN_OS = "18.0"
TINT = "6152DF"

PLATFORMS = {
    "ios": {
        "asset": "AIOStreams.ipa",
        "prefix": "KhanAIOStreams-",
        "exclude_prefix": "KhanAIOStreams-tvOS-",
        "bundle": "com.skhan85.khanaiostreams",
        "source": "Khan AIOStreams for iOS",
        "identifier": "com.skhan85.khanaiostreams",
        "subtitle": "An unofficial iPhone and iPad port of AIOStreams.",
        "description": (
            "An unofficial iPhone and iPad port of the AIOStreams app. It runs AIOStreams' own "
            "web app over AetherEngine, with Infuse as the default player, HDR10, HDR10+, Dolby Vision "
            "and Atmos, trailers, Picture in Picture and downloads. Not affiliated with AIOStreams or AetherEngine."
        ),
        "screenshots": ("iphone-home", "iphone-show", "iphone-movie", "iphone-versions"),
        "entitlements": [],
        "privacy": {
            "NSLocalNetworkUsageDescription": "Khan AIOStreams connects to your server and streams on your local network.",
            "NSMicrophoneUsageDescription": "Voice search in the page's search field uses the microphone.",
        },
    },
    "tvos": {
        "asset": "AIOStreams-tvOS.ipa",
        "prefix": "KhanAIOStreams-tvOS-",
        "exclude_prefix": None,
        "bundle": "com.skhan85.khanaiostreams.tv",
        "source": "Khan AIOStreams for Apple TV",
        "identifier": "com.skhan85.khanaiostreams.tv",
        "subtitle": "An unofficial Apple TV app for AIOStreams.",
        "description": (
            "An unofficial native Apple TV app for AIOStreams, built to look and work like the official "
            "apps, with Infuse handoff by default and AetherEngine built in: HDR10, HDR10+, Dolby Vision "
            "and Atmos, Live TV with a guide and catch-up, watch parties, Top Shelf and more. "
            "Not affiliated with AIOStreams or AetherEngine."
        ),
        "screenshots": ("tv-home", "tv-show", "tv-movie", "tv-player"),
        # Top Shelf shares what's on with the app through this App Group.
        "entitlements": ["com.apple.security.application-groups"],
        "privacy": {
            "NSLocalNetworkUsageDescription": "Khan AIOStreams connects to your server and streams on your local network.",
        },
    },
}


def releases_from(path):
    """`gh api --paginate` writes one JSON list per page, back to back."""
    text = open(path, encoding="utf-8").read()
    decoder = json.JSONDecoder()
    found, at = [], 0
    while at < len(text):
        while at < len(text) and text[at].isspace():
            at += 1
        if at >= len(text):
            break
        page, at = decoder.raw_decode(text, at)
        found.extend(page if isinstance(page, list) else [page])
    return found


def version_of(tag):
    """Returns ((major, minor, patch), build_number_or_None) for `vX.Y.Z` or `build-X.Y.Z-N`."""
    match = re.fullmatch(r"build-(\d+)\.(\d+)\.(\d+)-(\d+)", tag or "")
    if match:
        parts = tuple(int(p) for p in match.groups())
        return parts[:3], parts[3]
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", tag or "")
    return (tuple(int(p) for p in match.groups()), None) if match else (None, None)


def find_asset(assets, platform):
    exact = next((a for a in assets if a.get("name") == platform["asset"]), None)
    if exact:
        return exact
    prefix = platform["prefix"]
    exclude = platform["exclude_prefix"]
    return next(
        (
            a for a in assets
            if (a.get("name") or "").startswith(prefix)
            and (a.get("name") or "").endswith(".ipa")
            and not (exclude and (a.get("name") or "").startswith(exclude))
        ),
        None,
    )


def plain(notes):
    """Release notes as AltStore shows them: plain text, without Markdown's marks."""
    text = notes or ""
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"^#+\s*", "", text, flags=re.M)
    text = text.replace("**", "").replace("`", "")
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def main():
    releases_path, repo, tag, ipa, out = sys.argv[1:6]
    platform = PLATFORMS[sys.argv[6] if len(sys.argv) > 6 else "ios"]
    current_asset_name = os.path.basename(ipa)
    raw = f"https://raw.githubusercontent.com/{repo}/main"

    data = open(ipa, "rb").read()
    current = {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}

    versions = []
    for release in releases_from(releases_path):
        number, build = version_of(release.get("tag_name"))
        if release.get("draft") or release.get("prerelease") or not number or number < FIRST:
            continue
        asset = find_asset(release.get("assets", []), platform)
        is_current = release["tag_name"] == tag
        if not asset and not is_current:
            continue
        asset_name = current_asset_name if is_current else asset["name"]
        download_url = (
            f"https://github.com/{repo}/releases/download/{release['tag_name']}/{asset_name}"
            if is_current or not asset.get("browser_download_url")
            else asset["browser_download_url"]
        )
        entry = {
            "version": ".".join(map(str, number)),
            "date": release.get("published_at") or release.get("created_at"),
            "localizedDescription": plain(release.get("body")),
            "downloadURL": download_url,
            "size": current["size"] if is_current else asset["size"],
            "minOSVersion": MIN_OS,
        }
        if build is not None:
            entry["buildVersion"] = str(build)
        if is_current:
            entry["sha256"] = current["sha256"]
        versions.append(((*number, build or 0), entry))
    versions.sort(key=lambda pair: pair[0], reverse=True)

    source = {
        "name": platform["source"],
        "identifier": platform["identifier"],
        "subtitle": platform["subtitle"],
        "website": f"https://github.com/{repo}",
        "iconURL": f"{raw}/AIOStreams/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
        "tintColor": TINT,
        "apps": [
            {
                "name": "Khan AIOStreams",
                "bundleIdentifier": platform["bundle"],
                "developerName": "skhan85",
                "subtitle": "Your AIOStreams server, played through Infuse or AetherEngine.",
                "localizedDescription": platform["description"],
                "iconURL": f"{raw}/AIOStreams/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
                "tintColor": TINT,
                "category": "entertainment",
                "screenshots": [
                    f"{raw}/docs/screenshots/{name}.jpg"
                    for name in platform["screenshots"]
                ],
                "versions": [entry for _, entry in versions],
                "appPermissions": {
                    "entitlements": platform["entitlements"],
                    "privacy": platform["privacy"],
                },
            }
        ],
        "news": [],
    }
    with open(out, "w", encoding="utf-8") as handle:
        json.dump(source, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    print(f"{out}: {len(versions)} versions, newest {versions[0][1]['version'] if versions else 'none'}")


if __name__ == "__main__":
    main()
