# Security Policy

## Supported versions

Security fixes are applied to the latest development branch.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub Security Advisories for this
repository. Do not open a public issue containing credentials, private meeting data,
recordings, access tokens, or exploitable details.

Include:

- affected version or commit
- macOS version and hardware architecture
- reproduction steps using synthetic data
- expected and observed behavior
- relevant logs with secrets and personal data redacted

## Repository hygiene

- Never commit recordings, databases, `.venv`, model caches, `.env` files, keys, or tokens.
- Use synthetic audio and fictional participant names in tests and issues.
- Review `git ls-files` and run a secret scan before publishing the repository.
- Rotate any credential that was accidentally committed; deleting the file is not enough.
