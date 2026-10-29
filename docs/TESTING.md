# Testing

Three layers, cheapest first. Everything below runs without repository
secrets; the CI jobs only differ in what they wrap.

| Layer | Command | Runs in |
|---|---|---|
| Static checks (no Docker) | `scripts/check-static.sh` | `pull-request.yml` → `static` job, before the build |
| Architecture execution | `scripts/test-image-arch.sh <image> <platform>` | `upstream-release.yml` → `arch-test` job (linux/arm64, linux/arm/v7) |
| Full stack boot | `scripts/smoke-compose.sh <image>` | `pull-request.yml` → `verify` job, `upstream-release.yml` → `smoke` job |

## Static checks

```sh
scripts/check-static.sh
```

Exits non-zero when any check fails, prints one `PASS`/`SKIP`/`FAIL` line per
check and never builds or starts the image, so it finishes in seconds.

| Check | What it proves |
|---|---|
| `bash -n` on every `*.sh` | no syntax error in any script, including the POSIX ones (`bash -n` parses `#!/bin/sh` files fine) |
| ShellCheck on every `*.sh` | shell bugs: unquoted expansions, unreachable branches, useless cats. Uses `--severity=warning` by default so older style-level `info` findings do not block a pull request |
| actionlint on `.github/workflows/*.yml` | workflow syntax, invalid `uses:` references, wrong `needs:`/`matrix:` keys, shell quoting inside `run:` blocks, and `github.event` typos |
| YAML parse of every workflow, `.github/dependabot.yml` and `compose.yaml` | the files are valid YAML with a non-empty top-level document |
| `docker compose config -q` | `compose.yaml` resolves: variable defaults, anchors, volume source paths, and service keys |

Missing tools are **skipped, never failed**, so a fresh macOS checkout still
gives a useful answer:

```text
$ scripts/check-static.sh
PASS  bash -n: 6 script(s)
SKIP  shellcheck: not installed (brew install shellcheck / apt-get install shellcheck)
PASS  actionlint: 3 workflow(s) [1.7.7]
PASS  yaml: 5 file(s) parse with python3/yaml.safe_load
PASS  compose: docker compose config -q

0 failure(s), 1 skipped
PASS: static checks
```

`actionlint` is not installed on `ubuntu-latest`, so when it is missing the
script downloads the pinned release (`ACTIONLINT_VERSION`, pinned in
`pull-request.yml` as well) into a temporary directory with `curl`, uses it, and
deletes it on exit. Nothing is installed system-wide and no marketplace action
is needed. Offline machines fall back to a `SKIP` line.

Environment:

| Variable | Default | Meaning |
|---|---|---|
| `ACTIONLINT_VERSION` | `1.7.7` | release to download; `none` disables the download |
| `SHELLCHECK_SEVERITY` | `warning` | ShellCheck `--severity` |
| `NO_DOWNLOAD` | unset | `1` forbids every download, so missing tools are skipped |

`shellcheck` and `actionlint` are preinstalled on the GitHub runners or
downloaded by the script; on a laptop `brew install shellcheck actionlint` (or
`apt-get install shellcheck`) is enough.

## Smoke test (full stack)

```sh
docker build -t observium:test .
scripts/smoke-compose.sh observium:test
# keep the throwaway directory and its database for debugging
scripts/smoke-compose.sh observium:test --keep
```

The script boots `compose.yaml` plus two SNMP test hosts in a `mktemp -d`
directory, so it always starts from an empty database and never touches
`./data`. It asserts, among other things:

- both containers become healthy and `GET /` answers `HTTP 200` within 180 s;
- the `observium` container did not restart and the entrypoint log has no
  `ERROR`;
- the schema import is complete (`lower_case_table_names=1`,
  `devices.device_id` is `AUTO_INCREMENT`), the admin user exists once, and the
  default dashboard plus at least six widgets exist;
- **`GET /` without a session does not render `Logout`**, i.e. the UI is not
  open by default;
- **a login with a deliberately wrong password does not produce an
  authenticated session** (the follow-up request still does not render
  `Logout`);
- a correct login renders the dashboard;
- two devices added with the real `add_device.php` against live SNMP agents get
  distinct non-zero `device_id`s **and their RRD directory exists inside the
  container** (`/opt/observium/rrd/<host>`);
- `delete_device.php` removes them, and a second start of the entrypoint is
  idempotent (no duplicate admin/dashboard/widget rows, no resurrected
  devices, no restart).

Environment: `SMOKE_HTTP_PORT`, `SMOKE_ADMIN_USER`, `SMOKE_ADMIN_PASSWORD`,
`SMOKE_SNMPD_IMAGE`. Requires Docker with Compose v2 and `curl`. Runtime is
roughly 1-3 minutes after the image exists.

## Architecture execution

```sh
# the image must already exist locally for that platform
docker pull --platform linux/arm64 <image>@<digest>
scripts/test-image-arch.sh <image>@<digest> linux/arm64 <expected-php-version>
```

`scripts/test-image-arch.sh <image-ref> <platform> [expected-php-version]` runs
the image with `docker run --platform` and asserts:

- `php -v` runs and reports a version;
- that version matches the `org.observium.php.version` label baked into the
  image **and** the version passed as the third argument /
  `EXPECTED_PHP_VERSION` (each is compared when present; both must agree with
  what actually runs). An image built without the `PHP_VERSION` build arg has
  an empty label, so only the argument is compared, and with neither available
  the check is reported as `SKIP`;
- PHP-FPM exists and is executable (`/usr/sbin/php-fpm8.5`);
- `nginx -t` passes with the configuration baked into the image;
- `/usr/local/bin/entrypoint.sh` (from `docker/entrypoint.sh`) is executable;
- `PHP_INT_SIZE` is `8` on `linux/amd64` and `linux/arm64` and `4` on
  `linux/arm/v7` (a 32-bit PHP cannot run the 64-bit code paths Observium
  uses);
- the kernel architecture reported by PHP matches the requested platform, so a
  silently ignored `--platform` fails instead of passing.

Supported platforms are limited to the ones the image publishes; anything else
exits `2` with a message pointing at the table in the script.

### Why only `arch-test` runs under QEMU

`upstream-release.yml` builds `linux/amd64`, `linux/arm64` and `linux/arm/v7`
simultaneously, then:

- `smoke` boots the **linux/amd64** image with the full Compose stack;
- `arch-test` pulls the **arm64** and **armv7** digests under QEMU and runs
  `scripts/test-image-arch.sh` against them.

The full stack is deliberately not booted on the emulated platforms. Booting it
means MariaDB, PHP-FPM, nginx, the schema import and two SNMP sidecars under
emulation: minutes of QEMU time per release, on a runner that is already the
slowest part of the pipeline, with a real chance of timing out for reasons that
have nothing to do with the image. The parts it would exercise above the image
— the entrypoint, `db-entrypoint.sh`, the schema import, login and device
management — are architecture-independent shell/PHP/SQL that the amd64 `smoke`
job already covers on every release and every pull request. What is genuinely
architecture-specific is whether the binaries run at all, which is exactly what
`arch-test` checks.

The tradeoff accepted: a bug that only appears on 32-bit ARM in the *stack*
above the image (not in the binaries) would not be caught before publishing.

Publishing is not delayed more than necessary: `arch-test` runs in **parallel**
with `smoke`, and `push` waits for both, so the extra wall-clock cost is the
slower of the two jobs rather than their sum. It re-uses the digest that was
already pushed (`docker pull --platform` of the exact per-platform digest) and
does not rebuild the image from the Dockerfile, which would cost a full
emulated apt/PHP install per platform:

- pulling the digest tests the exact bytes that would be tagged — the same
  artefact the release publishes;
- rebuilding with `docker buildx build --platform <p> --load` from the same
  context would only add GHA-cache reuse, and would test a *different* artefact
  than the one being released.

Both jobs are bounded (`timeout-minutes: 25` for `arch-test`), and
`arch-test` uses `fail-fast: false` so a broken armhf image still reports the
arm64 result.

## What each CI job proves

`pull-request.yml` (untrusted contributor code, `pull_request`, `contents:
read`, GitHub-hosted runners only):

| Job | Proves |
|---|---|
| `static` | the contribution parses: shell scripts, workflows, YAML, `compose.yaml`. Runs before the build and fails fast. It executes the contributor's `scripts/check-static.sh`, so its trust model is the same as `verify` (read-only token, no secrets, GitHub-hosted runner); the tools it runs only parse the files |
| `verify` | the contributor's `Dockerfile` builds and their `compose.yaml` boots into a working Observium, with the assertions listed above |

`upstream-release.yml` (trusted, scheduled or manual):

| Job | Proves |
|---|---|
| `release-gate` | whether publishing is needed, and the build tag |
| `build` | all three platform images build, the PHP patch inside each matches the base image and the label, and their digests are recorded |
| `smoke` | the amd64 digest that is about to be tagged boots and works |
| `arch-test` | the arm64 and armv7 digests execute under QEMU (see above) |
| `push` | the multi-arch manifest is created only after all of the above |
| `github-release` | the release notes and the published component versions |

## Dependencies and workflow security

`.github/dependabot.yml` opens one grouped pull request per week for each
ecosystem:

- `github-actions` — every `uses:` in `.github/workflows/`, so a moved major tag
  is reviewed deliberately instead of silently following `@v6`;
- `docker` — the `FROM` images in `Dockerfile` (`debian:13-slim`) and the
  `image:` lines in `compose.yaml` (`mariadb:11`).

Both use the `ci` commit prefix, so a dependency bump lands through the same
`pull-request.yml` gates (static checks plus the full smoke test) as any other
change. Actions are pinned to major tags (`actions/checkout@v6`), which is what
Dependabot can follow; `pull-request.yml` keeps `persist-credentials: false`,
`permissions: contents: read` and never runs on a self-hosted runner, so an
untrusted pull request cannot reach a token or a secret.

## Troubleshooting

- `FAIL compose: docker compose config -q` — usually an unresolved `${VAR}` in
  `compose.yaml` or a wrong indentation; run the command by hand for the full
  message.
- `SKIP shellcheck` in CI would mean the runner image changed; install it in the
  job if that ever happens.
- `could not run ... with --platform linux/arm64 ... the local image is
  linux/amd64` — the image is not present for that platform. Pull it with
  `--platform` first; on a non-native platform QEMU must be registered
  (`docker run --privileged --rm tonistiigi/binfmt --install all`, or
  `docker/setup-qemu-action` in CI).
- The smoke test keeps its directory with `--keep`; `docker compose -p
  observium-smoke-<pid> logs` shows the stack after a failure.
