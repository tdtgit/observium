## What changed and why

<!-- One or two paragraphs. What does this change do, and what problem does it
     solve? Link the issue if there is one: "Fixes #123". -->

## How it was verified

<!-- Check what you actually ran, not what you plan to run. -->

- [ ] `bash -n docker/entrypoint.sh scripts/smoke-compose.sh`
- [ ] `sh -n docker/db-entrypoint.sh scripts/sury-php-version.sh`
- [ ] `docker compose config -q`
- [ ] `docker build -t observium:dev .`
- [ ] `scripts/smoke-compose.sh observium:dev`
- [ ] Tested on an existing deployment (`docker compose pull && docker compose up -d`), not only from an empty database
- [ ] Not verified locally — explanation:

Image tag or digest that was tested, if a published image was involved:

```text
```

## Image and behaviour impact

<!-- Delete what does not apply. -->

- Behaviour change visible to users: yes / no
- Requires a `./data` migration or reset: yes / no
- Changes the image size, build time, or boot time: yes / no
- New or changed environment variables are defaulted in `compose.yaml` and documented in `README.md`: yes / no / not applicable

## Security checklist

Complete this if the change touches `.github/workflows/`, `Dockerfile`,
`docker/`, `compose.yaml`, or `scripts/`.

- [ ] No secret is referenced, echoed, or passed to a build step
- [ ] Pull request workflows still use `pull_request`, not `pull_request_target`
- [ ] Token permissions are still minimal (`permissions: contents: read` unless justified in the diff)
- [ ] Nothing is pushed or published from a pull request workflow
- [ ] No self-hosted runner is introduced for code that builds or boots contributor input
- [ ] Nothing new is fetched over plain HTTP, or a checksum pins what is downloaded
