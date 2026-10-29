# Contributing

## What this repository is

This repository packages **Observium Community Edition** as a Docker image. It
contains the `Dockerfile`, the container bootstrap scripts in `docker/`, a
`compose.yaml` for a local app + MariaDB stack, the verification scripts in
`scripts/`, and the release automation in `.github/workflows/`.

It does not contain Observium itself. The application is downloaded from
upstream during the image build:

- Bugs in the Observium application, its UI, polling, or device support belong
  upstream, not here: <https://www.observium.org>
- Bugs in the image, the `Dockerfile`, `compose.yaml`, the entrypoints, or the
  release workflows belong in this repository.

Before opening an issue, check whether the behaviour still occurs with the
current `:latest` image, and include the image tag or digest you tested.

## Requirements

- Docker with Compose v2 (`docker compose version` must work; the v1
  `docker-compose` binary is not used).
- Roughly 10 GB of free disk for the image, the build cache, and a test stack
  with its database and RRD data.
- Network access during the build: the PHP base image, Debian packages and the
  upstream Observium tarball are fetched at build time.
- Optional: `python3` (used by `scripts/smoke-compose.sh` to pick a free host
  port; without it the script falls back to port `18080`).

The first build takes minutes because it installs the base system, PHP, and
Observium. Later builds reuse the Docker layer cache.

## Build and boot

Build a local image:

```bash
docker build -t observium:dev .
```

Boot the stack with that image instead of the published one:

```bash
OBSERVIUM_IMAGE=observium:dev docker compose up -d
```

The web UI is then on <http://localhost:8080> (set `OBSERVIUM_HTTP_PORT` to use
another host port). Logs:

```bash
docker compose logs -f observium
```

Tear down, including local data:

```bash
docker compose down
rm -rf ./data/db ./data/rrd ./data/logs
```

`./data` holds the MariaDB data directory, the RRD files, and the Observium
logs. Deleting it resets the installation. It is never committed.

## Verify a change

### Static checks

Start with the checks that do not need Docker:

```bash
scripts/check-static.sh
```

It runs `bash -n` on every shell script, ShellCheck and actionlint when they are
installed, parses every workflow and `compose.yaml`, and validates the Compose
file when Docker is available. It prints `PASS`/`SKIP`/`FAIL` per check and
exits non-zero on a failure. The `static` job in `pull-request.yml` runs the same
script before it builds the image.

### Smoke test

`scripts/smoke-compose.sh` boots a throwaway stack against any image reference
and checks that it actually works: both containers become healthy, the web UI
answers `HTTP 200`, the schema import completed, the admin login works, devices
can be added and deleted with the real `add_device.php`/`delete_device.php`
against test SNMP agents, the authentication boundary holds (anonymous access
never renders the dashboard, a wrong password never creates a session), polling
creates each device's RRD directory, and a second start of the entrypoint is
idempotent.

```bash
docker build -t observium:dev .
scripts/smoke-compose.sh observium:dev
```

The stack runs in a temporary directory, so it always starts from an empty
database and never touches `./data`. Options:

- `--keep` keeps the temporary stack directory for inspection.
- `SMOKE_HTTP_PORT` pins the host port instead of picking a free one.
- `SMOKE_ADMIN_USER` / `SMOKE_ADMIN_PASSWORD` override the credentials used for
  the login check (default `admin`/`admin`).

This is the same test the pull request workflow and the release workflow run, so
a change that passes it locally will not fail CI for a boot reason.

### Manual syntax checks

`scripts/check-static.sh` covers this; by hand, parse the shell scripts and the
Compose file before pushing:

```bash
bash -n docker/entrypoint.sh scripts/smoke-compose.sh
sh -n docker/db-entrypoint.sh
docker compose config -q
```

Use `sh -n` for the scripts whose shebang is `#!/bin/sh`: they run inside the
MariaDB image or on minimal hosts and must stay POSIX-compatible.

## Style

Match the surrounding code; there is no formatter or linter step in CI.

Shell scripts:

- bash, `#!/usr/bin/env bash`, and `set -euo pipefail` at the top of scripts
  that drive Docker or run inside the image (`docker/entrypoint.sh`,
  `scripts/smoke-compose.sh`).
- Scripts that run in a minimal environment stay POSIX `#!/bin/sh`
  (`docker/db-entrypoint.sh`, which the MariaDB image runs). Do not add
  bashisms to them.
- 2-space indent, quote variable expansions.
- Non-obvious behaviour gets a long explanatory comment above it. The scripts
  encode real failure modes (schema import, `lower_case_table_names`, restart
  idempotency); explain why, not what.
- Fail loudly: log with the script's existing prefix (`[entrypoint]`, `[smoke]`)
  and exit non-zero rather than continuing after an unexpected state.

Workflows in `.github/workflows/`:

- Pull request workflows use `pull_request`, never `pull_request_target`, so
  fork pull requests get a read-only token and no secrets.
- `permissions: contents: read` unless a job genuinely needs more, and then only
  in that job.
- Do not add secrets, registry pushes, or self-hosted runners to a pull request
  workflow. See "Do not" below.

Markdown and YAML:

- Wrap prose at roughly 80 columns, matching most of `README.md`.
- Keep the factual, direct voice of `README.md`: state what the thing does and
  what the constraint is, without marketing language.

Commit messages: `area: lowercase summary`, for example:

```text
ci: tolerate curl's expected EPIPE in the upstream version probe
fix: create the database with lower_case_table_names=1
feat: show installed components and image size in release notes
docs: add contribution guide and issue templates
```

Common areas: `ci`, `feat`, `fix`, `docs`, `style`, `chore`. Keep the summary
imperative and lowercase; put the why in the body when it is not obvious.

Branch names: `area/short-topic`, for example `ci/startup-smoke-test`,
`fix/device-schema-import`, or `docs/contributing`.

## Proposing a change

1. Open an issue first for anything that changes behaviour: the image contents,
   environment variables, the `compose.yaml` services, the entrypoint logic, or
   the release process. Small fixes (typos, broken links, an obviously wrong
   command in the docs) can go straight to a pull request.
2. Keep the pull request small and focused: one concern per pull request. Split
   unrelated fixes; a reviewer should be able to hold the whole change in their
   head.
3. Do not reformat, reorder, or "tidy" code you are not otherwise changing. It
   makes the diff unreadable and the review slower.
4. Describe what changed, why, and how you verified it, using the pull request
   template. Include the image tag or digest if you tested a published image.
5. Expect the pull request workflow to build your image and run
   `scripts/smoke-compose.sh` against it. A red run is a real boot failure until
   proven otherwise; reproduce it locally with the same two commands.

## What a reviewer will check

- Does the change do what the description says, and only that?
- Does the stack still boot from an empty database, and is a second start still
  idempotent? (Run the smoke test.)
- Does an existing deployment still work after `docker compose pull`? Changes
  that alter `./data` layout or the schema import need a migration path or an
  explicit note in `README.md`.
- Are new environment variables defaulted in `compose.yaml` with
  `${VAR:-default}` and documented in the `README.md` tables?
- Is the image still built for `linux/amd64`, `linux/arm64`, and `linux/arm/v7`
  without architecture-specific assumptions? `linux/arm/v7` has 32-bit PHP
  integers.
- For workflow changes: is the token still read-only for pull requests, and is
  nothing pushed or published from a pull request?
- Are failures reported, not swallowed? A script that continues after an
  unexpected state will hide a broken release.

## Do not

- Do not reference secrets in a pull request workflow, and do not add a
  `pull_request_target` trigger. Contributor code is untrusted.
- Do not route an image build that runs contributor code to a self-hosted
  runner. Building an untrusted `Dockerfile` and booting an untrusted
  `compose.yaml` is arbitrary code execution on the host.
- Do not push images from pull request workflows. Publishing happens only in
  `upstream-release.yml`, from its weekly schedule or a manual dispatch; do not
  add a trigger that can publish from a pull request.
- Do not reformat unrelated code, rename files, or bump unrelated dependencies
  in the same pull request.
- Do not commit the contents of `./data`, build output, or a filled-in `.env`.
- Do not invent version numbers or release notes. Versions are resolved from the
  build and written by the workflows; see `release-notes/README.md` for how a
  manual release note is supplied.

## Reporting a security issue

Do not open a public issue for a vulnerability. Use the repository's private
advisory form:
<https://github.com/tdtgit/observium/security/advisories/new>

## Code of conduct

Participation in this repository is covered by
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
