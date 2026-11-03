#!/bin/zsh
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
venv_path="$task_root/.venv"

if ! command -v python3 >/dev/null 2>&1; then
    echo "需要 Python 3.10 或更高版本。" >&2
    exit 1
fi

python3 -m venv "$venv_path"
"$venv_path/bin/python3" -m pip install --upgrade pip
"$venv_path/bin/python3" -m pip install -r "$task_root/MeetingCopilot/Resources/Scripts/requirements-transcription.lock"

echo
echo "转写环境已安装：$venv_path"
echo "MeetingCopilot 会自动使用这个 Python 环境。"
