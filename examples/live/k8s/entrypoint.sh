#!/bin/bash
set -euo pipefail

# if [[ -f /opt/conda/etc/conda/activate.d/lal_data_path.sh ]]; then
#   # shellcheck disable=SC1091
#   source /opt/conda/etc/conda/activate.d/lal_data_path.sh
# fi

/usr/sbin/sshd -D &
trap 'kill $(jobs -p) 2>/dev/null || true' EXIT

if [[ $# -eq 0 ]]; then
  wait
else
  exec "$@"
fi
