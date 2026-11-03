#!/usr/bin/env bash
set -euo pipefail
lab=$(cd "$(dirname "$0")" && pwd)
repository=$(cd "$lab/../../.." && pwd)
task_root=${1:?Usage: bash verify.sh /absolute/path/to/local-lab}
mkdir -p "$task_root"
python3 -m venv "$task_root/venv"
"$task_root/venv/bin/pip" install -r "$lab/requirements.txt"
"$task_root/venv/bin/python" "$lab/test_masks.py"
"$task_root/venv/bin/python" "$lab/models.py" "$task_root/models"
"$task_root/venv/bin/python" "$lab/acquire.py" "$task_root/data" --manifest "$repository/docs/comic-translation/lab/corpus.json"
"$task_root/venv/bin/python" "$lab/run.py" --corpus "$task_root/data" --models "$task_root/models" --output "$task_root/review" --regions 440 --ocr
"$task_root/venv/bin/python" "$lab/annotate.py" "$task_root/review/index.html"
