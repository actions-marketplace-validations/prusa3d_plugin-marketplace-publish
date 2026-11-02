# Contributing

Bug reports, fixes and improvements are welcome.

## Issues

- **A bug in the action:** open an issue with the workflow log (the `::error::` line and what
  comes before it) and the inputs you use. Remove anything secret first.
- **A release the marketplace refused or a problem with your author account:** that is the
  marketplace, not this action. The error message says why; ask in the author console or open
  an issue here and we will route it.
- **A security problem:** never in a public issue, see [SECURITY.md](SECURITY.md).

## Pull requests

1. Open an issue first for anything bigger than a small fix, so we can agree on the approach.
2. Keep the action a single Bash script with no dependencies beyond what GitHub's runners ship
   (`jq`, `openssl`, `zip`, `curl`). It runs with the author's signing key, so less code is
   easier to trust.
3. Add a case to `tests/selftest.sh` for a behaviour you change, and run the checks locally:

   ```bash
   shellcheck publish.sh tests/selftest.sh
   ./tests/selftest.sh
   ```

   CI runs both on Ubuntu and macOS. Workflows from a first-time contributor's pull request run
   after a maintainer approves them.
4. Update the README when inputs, outputs or behaviour change.

A maintainer reviews every pull request. Releases (`v1.x.y`, and moving `v1`) are made by the
maintainers after merging.

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
