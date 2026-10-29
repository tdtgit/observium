## What changed and why

<!-- Two or three sentences. What does this change? Why is it needed?
     Link the issue if there is one: "Fixes #123". -->

## How it was verified

<!-- Check only what you ran.
     Changed compose.yaml or the docs? Test the published image. No build needed.
     Changed the Dockerfile, docker/, or scripts/? Build your own image. -->

- [ ] `docker compose config -q`
- [ ] `scripts/smoke-compose.sh tuantuantuantuantuan/observium:latest` (no build; use this when only `compose.yaml` or docs changed)
- [ ] `docker build -t observium:dev .` (only if `Dockerfile`, `docker/`, or `scripts/` changed)
- [ ] `scripts/smoke-compose.sh observium:dev` (with the image built above)
- [ ] Tested on an existing deployment (`docker compose pull && docker compose up -d`), not only on a new database
- [ ] Not verified locally. Reason:

Shell syntax checks, only if a shell script changed:

```bash
bash -n docker/entrypoint.sh scripts/smoke-compose.sh
sh -n docker/db-entrypoint.sh scripts/sury-php-version.sh
```

Image tag or digest, if you tested a published image:

```text
```

## Impact

<!-- Delete the lines that do not apply. -->

- Users see a difference: yes / no
- Requires a `./data` migration or reset: yes / no
- Changes image size, build time, or boot time: yes / no
- New or changed environment variables are defaulted in `compose.yaml` and listed in `README.md`: yes / no / not applicable

## Security checklist

Complete this section only if the change touches `.github/workflows/`,
`Dockerfile`, `docker/`, or `scripts/`. A `compose.yaml` change needs only the
first two lines.

- [ ] No secret is referenced, printed, or passed to a build step
- [ ] Nothing is pushed or published from a pull request workflow
- [ ] Pull request workflows still use `pull_request`, not `pull_request_target`
- [ ] Token permissions are still minimal (`permissions: contents: read` unless the diff explains why not)
- [ ] No self-hosted runner is used for code that builds or starts contributor input
- [ ] Nothing new is downloaded over plain HTTP, unless a checksum pins the download
