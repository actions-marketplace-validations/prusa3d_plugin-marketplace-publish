# Publish to Prusa Plugin Marketplace

> [!NOTE]
> The Prusa Plugin Marketplace is in closed beta.

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

## Plugin id

The plugin's identity is the `id` in `manifest.json` (reverse-DNS, e.g. `com.example.flow-tower`)
and never changes. A new id must sit in a namespace you have proven in the author console under
*Namespaces*: a domain you own (`com.example.*`, by a DNS TXT record) or your GitHub account,
`io.github.<owner>.*`, which the first release from a repository of `<owner>` proves by itself.
Ids that read "prusa" are reserved for Prusa Research.

The name, description and links shown in the catalogue come from `manifest.json` on the first
release; later you change them in the author console, where every edit is moderated.

## Several plugins in one repository

One repository can hold any number of plugins, each in its own folder. Every release publishes
exactly one of them: the tag names the folder and the version.

```
your-account/slicer-plugins
├── .github/workflows/release.yml
└── plugins/
    ├── flow-tower/
    │   ├── manifest.json     "id": "io.github.your-account.flow-tower", "version": "1.2.0"
    │   └── main.lua
    └── gridfinity/
        ├── manifest.json     "id": "io.github.your-account.gridfinity", "version": "0.4.0"
        ├── main.lua
        └── assets/bin.svg
```

**1. One trusted publisher per plugin**, all with the same repository and workflow:

| Plugin id | Repository | Workflow |
|-----------|------------|----------|
| `io.github.your-account.flow-tower` | `your-account/slicer-plugins` | `release.yml` |
| `io.github.your-account.gridfinity` | `your-account/slicer-plugins` | `release.yml` |

**2. One workflow** that picks the folder from the tag:

```yaml
name: Publish to Plugin Marketplace
on:
  release:
    types: [published]
permissions:
  contents: read
  id-token: write
jobs:
  publish:
    runs-on: ubuntu-latest
    environment: release # optional, see Security
    steps:
      - uses: actions/checkout@v5
      - name: Pick the plugin from the tag
        id: plugin
        run: |
          name="${GITHUB_REF_NAME%/v*}"   # flow-tower/v1.2.0 -> flow-tower
          dir="plugins/$name"
          if [ ! -f "$dir/manifest.json" ]; then
            echo "::error::tag $GITHUB_REF_NAME names no plugin folder ($dir)"
            exit 1
          fi
          echo "dir=$dir" >> "$GITHUB_OUTPUT"
      - uses: prusa3d/plugin-marketplace-publish@v1
        with:
          path: ${{ steps.plugin.outputs.dir }}
          private-key: ${{ secrets.PRUSA_SLICER_PLUGIN_MARKETPLACE_SIGNING_KEY }}
```

**3. Release a plugin** by bumping `version` in its `manifest.json` and publishing a release with
the tag `<folder>/v<version>`:

```bash
gh release create flow-tower/v1.2.0 --title "Flow tower 1.2.0" --notes "Faster tower generation"
gh release create gridfinity/v0.5.0 --prerelease --notes "New bin sizes"   # beta channel
```

Only that folder is signed and uploaded. The action refuses a tag whose version does not match the
folder's `manifest.json`, and the marketplace accepts a bundle only for a plugin id this repository
and workflow are bound to, so one plugin's release can never publish another.

Each folder is a complete bundle: code shared between plugins has to be copied into every folder
that uses it (a build step before the action can do that). All plugins can be signed with the same
key.

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
