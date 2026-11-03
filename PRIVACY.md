# Privacy

MeetingCopilot is local-first. It does not include telemetry, analytics, ads,
or a built-in remote account system.

## Data stored on the Mac

- Audio recordings: `~/Movies/MeetingCopilot/`
- Meeting manifests, transcripts, minutes, and revisions: inside each meeting directory
- SwiftData index: the app's local application-data container
- User settings: macOS `UserDefaults`
- Local models and caches: created by the selected ASR/LLM tooling

Deleting a meeting or project moves its archive directory to the macOS Trash before
the local index is removed.

## Network boundaries

- ASR and speaker clustering run locally by default.
- The default minutes endpoint is `http://127.0.0.1:11434/api/generate`.
- If the user configures a non-local LLM endpoint, transcript text is sent to that
  endpoint to generate minutes.
- Hugging Face and model-download hosts may be contacted when model files are absent.
- No recording is uploaded to a MeetingCopilot-operated server.

## Secrets

Do not store credentials in meeting files, source code, screenshots, logs, or Git.
The optional Hugging Face token is read from `MEETINGCOPILOT_HF_TOKEN`. Secrets must
not be committed to the repository.

## Reminders

When the user chooses “同步到提醒事项”, confirmed action-item titles and metadata
are written to the user's macOS Reminders database through EventKit.
