# Security

Please report a vulnerability in this action privately, through GitHub's
[private vulnerability reporting](https://github.com/prusa3d/plugin-marketplace-publish/security/advisories/new),
not in a public issue.

The action signs the bundle inside the workflow run: the private key is never sent anywhere, and
the marketplace receives only the signed bundle and the run's short-lived OIDC token.
