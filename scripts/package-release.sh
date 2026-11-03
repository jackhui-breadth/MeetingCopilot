#!/bin/zsh
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "工作区有未提交改动，请先提交或忽略不需要发布的文件。" >&2
    exit 1
fi

version=$(/usr/libexec/PlistBuddy \
    -c "Print :CFBundleShortVersionString" \
    MeetingCopilot/Info.plist)

./scripts/build-app.sh

release_dir="$task_root/release"
mkdir -p "$release_dir"
find "$release_dir" -maxdepth 1 -type f \
    \( -name '*.zip' -o -name 'SHA256SUMS.txt' \) \
    -delete

app_archive="$release_dir/MeetingCopilot-$version-macOS-arm64-unsigned.zip"
ditto -c -k --sequesterRsrc --keepParent \
    "$task_root/dist/MeetingCopilot.app" \
    "$app_archive"

source_archive="$release_dir/MeetingCopilot-$version-source.zip"
git archive \
    --format=zip \
    --prefix="MeetingCopilot-$version/" \
    --output="$source_archive" \
    HEAD

cd "$release_dir"
shasum -a 256 *.zip > SHA256SUMS.txt
echo "发布文件："
ls -lh "$app_archive" "$source_archive" SHA256SUMS.txt
