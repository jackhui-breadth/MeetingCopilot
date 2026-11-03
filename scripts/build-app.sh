#!/bin/zsh
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$task_root/dist/MeetingCopilot.app"
contents_path="$app_path/Contents"

cd "$task_root"
swift build -c release

rm -rf "$contents_path/MacOS" "$contents_path/Resources"
mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
cp "$task_root/.build/release/MeetingCopilot" "$contents_path/MacOS/MeetingCopilot"
cp "$task_root/MeetingCopilot/Info.plist" "$contents_path/Info.plist"
mkdir -p "$contents_path/Resources/Scripts"
for resource in "$task_root/MeetingCopilot/Resources/Scripts/"*.py \
                "$task_root/MeetingCopilot/Resources/Scripts/"*.txt \
                "$task_root/MeetingCopilot/Resources/Scripts/"*.lock; do
    cp "$resource" "$contents_path/Resources/Scripts/"
done
cp "$task_root/LICENSE" "$contents_path/Resources/LICENSE"
cp "$task_root/PRIVACY.md" "$contents_path/Resources/PRIVACY.md"
cp "$task_root/THIRD_PARTY_NOTICES.md" "$contents_path/Resources/THIRD_PARTY_NOTICES.md"

for bundle in "$task_root"/.build/release/*.bundle; do
    if [[ -d "$bundle" ]]; then
        cp -R "$bundle" "$contents_path/Resources/"
    fi
done
find "$contents_path/Resources" -name '*.pyc' -delete

codesign --force --deep --sign - "$app_path"
echo "$app_path"
