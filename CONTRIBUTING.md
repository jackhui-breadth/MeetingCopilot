# Contributing

## Development

```bash
brew install ffmpeg
./scripts/setup-transcription.sh
swift test
python3 -m unittest discover -s scripts/tests -v
```

## Privacy requirements

- Use synthetic audio and fictional names in fixtures.
- Never commit real meeting audio, transcripts, database files, logs, credentials,
  model caches, or local absolute paths.
- Redact tokens, URLs, and personal information from screenshots and bug reports.
- Keep secrets in environment variables or a secret manager, never in SwiftData,
  meeting manifests, Markdown files, or source code.

## Pull requests

- Keep changes scoped and describe user-visible behavior.
- Add or update tests when touching archive writes, processing state, exports,
  permissions, or audio capture.
- Run both Swift and Python test suites and include the commands in the PR.
- Do not change licensing or vendored dependencies without documenting the impact.
