# Security Policy

This repository packages **Observium Community Edition** into a Docker image
(Debian 13 + Nginx + PHP 8.5-FPM, published as
`tuantuantuantuantuan/observium`) and ships the Compose stack, the container
entrypoint scripts and the CI workflows that build it.

## Supported versions

Fixes are delivered as new image builds, so only image tags that are still being
republished receive them:

| Version | Supported |
| --- | --- |
| `tuantuantuantuantuan/observium:latest` | yes, rebuilt by the weekly release workflow |
| The most recent dated build tags (for example `:2026.10.22-3`, one per build) | yes, until a newer build tag exists |
| Upstream version tags (`:26.1.14545`, `:25.4.0`), which move on rebuild | only while they point at a recent build |
| Older dated build tags | no |

Because a rebuild republishes `:latest` and the version tag, the fix for an
image finding is `docker compose pull && docker compose up -d`. Immutable dated
build tags are never rebuilt, so a fix always arrives under a new date.

Report the git commit or image tag/digest (`docker image inspect --format
'{{index .RepoDigests 0}}'`) you tested against.

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Use GitHub's private vulnerability reporting for this repository:

<https://github.com/tdtgit/observium/security/advisories/new>

That creates a private GitHub Security Advisory visible only to the
maintainers. If the form is unavailable, open an issue that says only "security
report, please enable private reporting" and no details, and a maintainer will
open a private channel.

Include:

- what the problem is and where (file, image tag, image digest),
- how to reproduce it, ideally with the smallest `compose.yaml`/command that
  shows it,
- the impact you believe it has,
- any suggested fix.

Never include credentials, private keys or data taken from someone else's
deployment.

## Scope

In scope — problems in the packaging in this repository:

- `Dockerfile` and the build (base image, package installation, file
  permissions, build arguments).
- `docker/entrypoint.sh` and `docker/db-entrypoint.sh` (admin bootstrap,
  schema handling, generated credentials, how environment variables end up in
  `config.php`).
- `compose.yaml` (published ports, default credentials, service wiring).
- `.github/workflows/*` (how images are built, smoke tested and published, and
  whether untrusted pull request code can reach secrets or a publish step).
- `scripts/` (smoke test, helper scripts).
- The published image, when the issue comes from how this repository assembles
  it: what is installed, what runs as root, what the entrypoint does at start.

Out of scope — problems in the application itself, which are upstream's:

- Vulnerabilities, authentication or authorisation flaws, XSS/SQL injection, or
  unsafe deserialisation in the Observium PHP code under
  `/opt/observium` (that code is the upstream tarball, not this repository).
- Missing application-level features such as MFA, session policy or LDAP/TLS
  options that upstream does not implement.
- Findings in third-party packages that have no fix available upstream yet, and
  that are not caused by how they are installed here.

Upstream Observium distributes its code from <https://www.observium.org/> and
does not use GitHub issues; report application problems through the contact
details on that site. If you are unsure whether a problem is ours or upstream's,
report it here and it will be forwarded.

## What this image does not do

The image is not hardened by default. It serves plain HTTP, the entrypoint runs
as root, `compose.yaml` publishes the web UI on all interfaces and ships default
database credentials. These are known, documented limitations, not
vulnerabilities: see [docs/SECURITY_HARDENING.md](docs/SECURITY_HARDENING.md)
for what to change before exposing the stack.

A note on images published before this policy: images built before the change
that removed the default administrator password booted with `admin`/`admin`
when `OBSERVIUM_ADMIN_USER`/`OBSERVIUM_ADMIN_PASSWORD` were left at their
defaults. Any deployment created from such an image has an administrator
account with a publicly known password until it is changed, even after
upgrading the image (an existing user is never recreated or reset). Check with:

```bash
docker compose exec -T db mariadb -uobservium -pobservium observium \
  -e "SELECT user_id, username, level FROM users;"
```

and change the password of any account that still uses `admin`.

## What we do about reports

- Acknowledgment of the report within 7 days.
- An initial assessment (confirmed / not a vulnerability / out of scope) within
  14 days, with the reasoning.
- Confirmed packaging issues are fixed in this repository, published as a new
  image build, and described in the release notes for that build. The advisory
  is published after the fixed image is available.
- Please give us 90 days before public disclosure; a shorter window is fine by
  agreement, and we will ask for an extension only if an upstream fix is
  involved.

There is no bug bounty and no payment for reports. Credit is given in the
advisory unless you ask otherwise.

## Hardening and verification

- [docs/SECURITY_HARDENING.md](docs/SECURITY_HARDENING.md) — deployment steps
  that must be taken before exposing the web UI.
- `.github/workflows/image-scan.yml` — weekly Trivy scan of the published image
  and a scan of every pull request build, uploaded as SARIF to GitHub code
  scanning.
