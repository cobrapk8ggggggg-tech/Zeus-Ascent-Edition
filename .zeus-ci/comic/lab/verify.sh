#!/usr/bin/env bash
set -euo pipefail
lab=$(cd "$(dirname "$0")" && pwd)
repository=$(cd "$lab/../../.." && pwd)
task_root=${1:?Usage: bash verify.sh /absolute/path/to/local-lab}
mkdir -p "$task_root"
python3 -m venv "$task_root/venv"
"$task_root/venv/bin/pip" install -r "$lab/requirements.txt"
for suite in test_masks.py test_flat_balloons.py test_balloons_and_ink.py test_cleanup_quality.py; do
  "$task_root/venv/bin/python" "$lab/$suite"
done
"$task_root/venv/bin/python" "$repository/tools/comic-corpus/full_lab.py" --root "$task_root"
