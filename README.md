# Publish to Prusa Plugin Marketplace

GitHub Action that signs a PrusaSlicer plugin bundle and publishes it to the
[Prusa Plugin Marketplace](https://plugin-marketplace.prusa3d.com) with **trusted publishing**:
the workflow proves which repository and workflow it is with the OIDC token GitHub issues to the
run. There is no marketplace password or API key to store.

Every release is still scanned and reviewed before it is public. This action only submits it.

## Setup

1. **Signing key.** Create an RSA key pair (2048 bits or more) and register the public key in the
   author console under *Signing keys*. An expired or revoked key no longer signs new releases:

   ```bash
   openssl genpkey -algorithm RSA -out private_key.pem -pkeyopt rsa_keygen_bits:2048
   openssl rsa -pubout -in private_key.pem -out public_key.pem
   ```

   Store the contents of `private_key.pem` as the repository secret `PRUSA_SLICER_PLUGIN_MARKETPLACE_SIGNING_KEY`.

2. **Trusted publisher.** In the author console under *Trusted publishing*, add the plugin id,
   `owner/repository`, the workflow file name (`release.yml`) and optionally a GitHub environment.
   A plugin id that does not exist yet is reserved for you; the first release creates it.

3. **Workflow.** Add `.github/workflows/release.yml`:

   ```yaml
   name: Publish to Plugin Marketplace
   on:
     release:
       types: [published]
   permissions:
     contents: read
     id-token: write # required: the run proves its identity with an OIDC token
   jobs:
     publish:
       runs-on: ubuntu-latest
       environment: release # optional, see Security
       steps:
         - uses: actions/checkout@v5
         - uses: prusa3d/plugin-marketplace-publish@v1
           with:
             path: .
             private-key: ${{ secrets.PRUSA_SLICER_PLUGIN_MARKETPLACE_SIGNING_KEY }}
   ```

4. **Release.** Publish a GitHub release whose tag ends with the `version` in `manifest.json`:
   `v1.2.0` or `1.2.0`. A pre-release goes to the beta channel; the release notes become the
   changelog.

## Several plugins in one repository

Add one trusted publisher per plugin, all with the same workflow, and tag each release with the
plugin's folder, e.g. `flow-tower/v1.2.0`:

```yaml
    steps:
      - uses: actions/checkout@v5
      - id: plugin
        run: echo "dir=plugins/${GITHUB_REF_NAME%/v*}" >> "$GITHUB_OUTPUT"
      - uses: prusa3d/plugin-marketplace-publish@v1
        with:
          path: ${{ steps.plugin.outputs.dir }}
          private-key: ${{ secrets.PRUSA_SLICER_PLUGIN_MARKETPLACE_SIGNING_KEY }}
```

The marketplace accepts a bundle only for a plugin id the repository and workflow are bound to,
so a release can never publish another plugin by accident.

## Inputs

| Input | Default | |
|-------|---------|---|
| `private-key` | (required) | RSA private key (PEM, 2048 bits or more) the bundle is signed with. Pass a secret. Its public key must be an active signing key in the author console. |
| `path` | `.` | Folder with `manifest.json` and the files the plugin ships. |
| `marketplace-url` | `https://plugin-marketplace.prusa3d.com` | Marketplace to publish to. |
| `channel` | auto | `stable` or `beta`. Empty: `beta` for a pre-release, `stable` otherwise. |
| `changelog` | release body | Release notes, Markdown. |
| `check-version` | `true` | For a tag run, require the tag to end with the manifest version (`v1.2.0`, `name/v1.2.0`, `id@1.2.0`). |
| `dry-run` | `false` | Build and sign only; the zip is in the `bundle` output. |

Outputs: `plugin-id`, `version`, `bundle` (path of the signed zip), `url` (the release in the
author console).

## What it does

1. Copies the folder, leaving out `.git`, `.github` and any old `manifest.txt` / `manifest.sig`.
2. Writes `manifest.txt` with the SHA-256 of every file and signs it into `manifest.sig`
   (`openssl dgst -sha256 -sign`, RSA PKCS#1 v1.5), then verifies the signature.
3. Zips the bundle with `manifest.json` at its root.
4. Requests the run's OIDC token with the marketplace as audience and uploads the bundle to
   `POST /api/publish/v1/releases`
   ([OpenAPI](https://plugin-marketplace.prusa3d.com/api/publish/v1/openapi.json)).

The private key is only used inside the run and is never sent anywhere. Uploading a version that
already exists fails with a clear message, so re-running a workflow is safe.

## Security

Anyone who can change the workflow can sign with the key in the repository secrets. Bind the
trusted publisher to a GitHub **environment** with required reviewers and add
`environment: <name>` to the job: then every publish waits for an approval, and runs outside that
environment are refused by the marketplace.

The marketplace remembers the repository's numeric GitHub id from the first release, so a
repository deleted and re-created under the same name by someone else cannot publish.

## License

MIT
