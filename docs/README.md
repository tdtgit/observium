# Documentation

Operational documentation for this Observium Docker packaging repository. Start
with the [README](../README.md) for installation, configuration and the
`lower_case_table_names` notes; the guides below go deeper.

| Document | Contents |
|---|---|
| [BACKUP_RESTORE.md](BACKUP_RESTORE.md) | What is stateful, logical database dumps and cold `./data` archives, restore into a fresh tree, post-restore verification, the executable `scripts/restore-drill.sh` drill, cron automation and retention |
| [UPGRADE_ROLLBACK.md](UPGRADE_ROLLBACK.md) | What the entrypoint runs on boot, tag semantics, pinning before an upgrade, the pre-upgrade checklist, rollback after a schema migration, and the limits of downgrades |
| [PINNING.md](PINNING.md) | Pinning image tags and digests for reproducible deployments |
| [TESTING.md](TESTING.md) | The Compose smoke test, running it locally, and the CI workflows |
| [ARCHITECTURE.md](ARCHITECTURE.md) | How the image, entrypoints, bind mounts and release pipeline fit together |
| [SECURITY_HARDENING.md](SECURITY_HARDENING.md) | Credentials, exposure, TLS and host hardening for this stack |
| [SECURITY.md](../SECURITY.md) | How to report a vulnerability |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | Branch, commit and pull request conventions |
| [README.md](../README.md) | Install, configure, verify, build and release |

Scripts and workflows referenced above live under
[`scripts/`](../scripts/) and [`.github/workflows/`](../.github/workflows/).
The two that change how a deployment behaves are worth knowing by name:
`scripts/pin-image.sh` (rewrite a tag to a digest and write `.env`) and
`scripts/restore-drill.sh <image-ref>` (prove a backup restores, nightly in
`restore-drill.yml`).
