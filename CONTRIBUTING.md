# Contributing

Short sentences, plain words. If something here is unclear, that is a bug in
this file, not in you.

## What this repository is

This repository packages **Observium Community Edition** as a Docker image.

It contains:

- the `Dockerfile`;
- the container startup scripts in `docker/`;
- a `compose.yaml` for a local stack with the app and MariaDB;
- the verification scripts in `scripts/`;
- the release automation in `.github/workflows/`.

It does not contain Observium. The image downloads Observium from upstream
during the build.

Where to report a problem:

- The Observium application itself: <https://www.observium.org>
- The image, `compose.yaml`, the startup scripts, or the workflows: this
  repository.

Test the current `:latest` image before you open an issue. Include the tag or
digest you tested.

## Requirements

- Docker with Compose v2. `docker compose version` must work. The old
  `docker-compose` binary is not used.
- About 10 GB of free disk space. The image, the build cache, and a test stack
  with its database and RRD files need it.
- Network access during the build. Debian packages, PHP from
  [sury](https://packages.sury.org/php), and the Observium tarball are
  downloaded at build time.
- Optional: `python3`. The smoke test uses it to find a free host port.
  Without it, the test uses port `18080`.

The first build takes several minutes. Later builds reuse the Docker layer
cache.

## Build and run

Build a local image:

```bash
docker build -t observium:dev .
```

Run the stack with that image:

```bash
OBSERVIUM_IMAGE=observium:dev docker compose up -d
```

The web UI is at <http://localhost:8080>. Set `OBSERVIUM_HTTP_PORT` to use
another host port. Follow the logs with:

```bash
docker compose logs -f observium
```

Remove the stack and its local data:

```bash
docker compose down
rm -rf ./data/db ./data/rrd ./data/logs
```

`./data` contains the MariaDB data directory, the RRD files, and the Observium
logs. Delete it to start over. Never commit it.

## Test your change

### Static checks

Start with the checks that do not need Docker:

```bash
scripts/check-static.sh
```

It runs `bash -n` on every shell script, ShellCheck and actionlint when they
are installed, parses every workflow and `compose.yaml`, validates the Compose
file when Docker is available, and self-tests `scripts/pin-image.sh`. It prints
`PASS`/`SKIP`/`FAIL` per check and exits non-zero on a failure. The `static`
job in `pull-request.yml` runs the same script before it builds the image.

### Smoke test

`scripts/smoke-compose.sh` starts a throwaway stack and tests it. The stack runs
in a temporary directory. It always starts from an empty database and never
touches `./data`.

The test checks that:

- both containers become healthy;
- the web UI answers `HTTP 200`;
- the schema import completed;
- the admin login works;
- devices can be added and deleted through `add_device.php` and
  `delete_device.php`, against test SNMP agents;
- the authentication boundary holds: anonymous access never renders the
  dashboard, and a wrong password never creates a session;
- polling creates each device's RRD directory;
- a second start of the entrypoint is idempotent.

If you changed the image (`Dockerfile`, `docker/`, or `scripts/`), build it
first:

```bash
docker build -t observium:dev .
scripts/smoke-compose.sh observium:dev
```

If you changed only `compose.yaml` or the documentation, test the published
image. No build is needed. The script copies `compose.yaml` from the repository
into its temporary directory, so it tests your change:

```bash
scripts/smoke-compose.sh tuantuantuantuantuan/observium:latest
```

Options:

- `--keep` keeps the temporary stack directory for inspection.
- `SMOKE_HTTP_PORT` sets the host port.
- `SMOKE_ADMIN_USER` and `SMOKE_ADMIN_PASSWORD` set the login used by the test.
  The defaults are `admin` and `admin`.

The pull request workflow and the release workflow run the same test. If it
passes locally, CI will not fail for a startup reason.

### Syntax checks

`scripts/check-static.sh` covers all of this. To check by hand:

```bash
bash -n docker/entrypoint.sh scripts/*.sh
docker compose config -q
```

Use `sh -n` for the scripts with a `#!/bin/sh` shebang. Those scripts must stay
compatible with POSIX `sh`. The MariaDB image runs `docker/db-entrypoint.sh`.

There is no linter or formatter step beyond that. If you add a new check, put
it in `scripts/check-static.sh` so the pull request workflow runs it.

## Style

Match the code around you. A reviewer will check this.

### Shell scripts

- bash scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`. This
  applies to `docker/entrypoint.sh` and `scripts/smoke-compose.sh`.
- POSIX scripts start with `#!/bin/sh`. This applies to
  `docker/db-entrypoint.sh` and `scripts/sury-php-version.sh`. Do not use bash
  features there.
- Use 2 spaces for indentation. Quote variable expansions.
- Add a short comment above non-obvious code. Explain why it is needed. The
  scripts handle real failures: the schema import, `lower_case_table_names`,
  and restart idempotency.
- Log with the prefix already used in the script (`[entrypoint]`, `[smoke]`).
  Exit with a non-zero status if the state is unexpected. Do not continue.

### Workflows

- Pull request workflows use `pull_request`. Never use `pull_request_target`.
  Pull requests from forks then receive a read-only token and no secrets.
- Use `permissions: contents: read` unless a job needs more. In that case, set
  the permission on that job only.
- Do not add secrets, registry pushes, or self-hosted runners to a pull request
  workflow. See "Do not" below.

### Markdown and YAML

- Wrap prose at about 80 columns.
- Keep sentences short. State the facts. Avoid promotional language.

### Commit messages

Use `area: lowercase summary`. Examples:

```text
ci: tolerate curl's expected EPIPE in the upstream version probe
fix: create the database with lower_case_table_names=1
feat: show installed components and image size in release notes
docs: add contribution guide and issue templates
```

Use `ci`, `feat`, `fix`, `docs`, `style`, or `chore` as the area. Write the
summary in the imperative and in lowercase. Add a body when the reason is not
obvious.

### Branch names

Use `area/short-topic`. Examples: `ci/startup-smoke-test`,
`fix/device-schema-import`, `docs/contributing`.

## Proposing a change

1. Open an issue first if the change affects behaviour. This includes the image
   contents, environment variables, the `compose.yaml` services, the entrypoint
   logic, and the release process. Small fixes can go straight to a pull
   request. Examples: a typo, a broken link, a wrong command in the docs.
2. Keep the pull request small. One concern per pull request. Split unrelated
   fixes.
3. Do not reformat code you did not change. It makes the diff hard to read.
4. Describe what changed, why, and how you verified it. Use the pull request
   template. If you tested a published image, give the tag or digest.
5. Expect CI to build your image and run `scripts/smoke-compose.sh` against it.
   A failed run means the stack does not start. Reproduce it locally with the
   same commands.
6. Work on a branch, never on `main`. `main` only moves through reviewed pull
   requests: push your branch, open the pull request, and let a reviewer merge
   it.

## What a reviewer checks

- The change does what the description says. It does nothing else.
- The stack starts from an empty database. A second start is still idempotent.
- An existing deployment still works after `docker compose pull`. Changes to
  the `./data` layout or to the schema import need a migration path. Otherwise
  document the reset in `README.md`.
- New environment variables are defaulted in `compose.yaml` with
  `${VAR:-default}` and listed in the `README.md` tables.
- The image still builds for `linux/amd64`, `linux/arm64`, and `linux/arm/v7`.
  The `linux/arm/v7` platform has 32-bit PHP integers.
- Workflow changes keep the pull request token read-only. Nothing is pushed or
  published from a pull request.
- Errors are reported. They are not ignored.

## Do not

- Do not reference secrets in a pull request workflow. Do not add a
  `pull_request_target` trigger. Contributor code is untrusted.
- Do not run contributor builds on a self-hosted runner. Building an untrusted
  `Dockerfile` and starting an untrusted `compose.yaml` runs arbitrary code on
  the host.
- Do not push images from a pull request workflow. Only `upstream-release.yml`
  publishes. It runs on a weekly schedule or by manual dispatch.
- Do not reformat unrelated code, rename files, or update unrelated
  dependencies in the same pull request.
- Do not commit `./data`, build output, or a filled-in `.env`.
- Do not push to `main`, force-push a reviewed branch, or merge without a
  review. A branch plus a pull request is the only way a change lands.
- Do not invent version numbers or release notes. The workflows resolve the
  versions. To supply a manual release note, see `release-notes/README.md`.

## Security issues

Do not open a public issue for a vulnerability. Use the private advisory form:
<https://github.com/tdtgit/observium/security/advisories/new>

## Code of conduct

Participation is covered by [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). That
document uses formal language on purpose. Follow it as written.
