#!/usr/bin/env python3
"""Read per-architecture image labels from a container registry.

Usage:
    scripts/image-php-labels.py <repository> <tag> [label-key]

Example:
    scripts/image-php-labels.py tuantuantuantuantuan/observium latest
    scripts/image-php-labels.py tuantuantuantuantuan/observium latest org.observium.php.version

Prints one "<arch>\t<value>" line per platform in the manifest index. Only
stdlib is used so it runs on a stock runner and on a workstation.
"""

import json
import sys
import urllib.parse
import urllib.request

REGISTRY = "registry-1.docker.io"
AUTH = "https://auth.docker.io/token"
ACCEPT = ",".join(
    (
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    )
)


def token(repository):
    query = urllib.parse.urlencode(
        {"service": "registry.docker.io", "scope": f"repository:{repository}:pull"}
    )
    with urllib.request.urlopen(f"{AUTH}?{query}", timeout=30) as response:
        return json.load(response)["token"]


def get(url, bearer, accept=None):
    request = urllib.request.Request(url)
    request.add_header("Authorization", f"Bearer {bearer}")
    if accept:
        request.add_header("Accept", accept)
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    repository, tag = sys.argv[1], sys.argv[2]
    label_key = sys.argv[3] if len(sys.argv) > 3 else None

    bearer = token(repository)
    index = get(
        f"https://{REGISTRY}/v2/{repository}/manifests/{tag}", bearer, ACCEPT
    )

    children = index.get("manifests") or []
    if not children:
        # Single-platform manifest: report it under its own digest.
        children = [index]

    rows = []
    for child in children:
        platform = child.get("platform") or {}
        architecture = platform.get("architecture") or "unknown"
        if architecture == "unknown":
            continue
        manifest = get(
            f"https://{REGISTRY}/v2/{repository}/manifests/{child['digest']}",
            bearer,
            ACCEPT,
        )
        config_digest = manifest.get("config", {}).get("digest")
        if not config_digest:
            continue
        config = get(
            f"https://{REGISTRY}/v2/{repository}/blobs/{config_digest}", bearer
        )
        labels = config.get("config", {}).get("Labels") or {}
        value = labels.get(label_key, "") if label_key else ""
        rows.append((architecture, value))

    for architecture, value in sorted(rows):
        print(f"{architecture}\t{value}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
