# GitHub publishing guide

## Repository metadata

Suggested repository name:

```text
MeetingCopilot
```

Suggested description:

> 本地优先的 macOS 会议录音、中文逐字稿、说话人区分、AI 纪要与行动项工作台。

Suggested topics:

```text
macos swift swiftui speech-to-text meeting-notes local-first ollama funasr
sensevoice apple-silicon privacy
```

## Before the first push

```bash
git status --short
git ls-files
rg -n --hidden -g '!.git/**' -g '!*.png' \
  '(api[_-]?key|password|token|PRIVATE KEY|BEGIN OPENSSH|/Users/)' .
find . -type f \( -iname '*.m4a' -o -iname '*.sqlite*' -o -iname '*.env' \)
```

Expected files are source, tests, documentation, requirements, and scripts only.
Recordings, `.venv`, `.build`, model caches, databases, and `dist` must remain ignored.

## Create the repository

Review the commit before publishing. Create a private repository first:

```bash
gh repo create MeetingCopilot --private --source=. --remote=origin --push
```

Once GitHub renders the README and CI, change visibility in repository settings.
Public visibility makes the complete Git history public.

## Package a release

```bash
./scripts/package-release.sh
```

The script refuses to package a dirty worktree and writes artifacts to `release/`.
The app bundle uses an ad-hoc development signature. Users who need a smooth,
Gatekeeper-approved binary release require Developer ID signing and Apple notarization.

## Create a GitHub release

```bash
git tag v0.1.0
git push origin v0.1.0
gh release create v0.1.0 release/* \
  --title "MeetingCopilot v0.1.0 Developer Preview" \
  --notes-file docs/RELEASE_NOTES_v0.1.0.md
```
