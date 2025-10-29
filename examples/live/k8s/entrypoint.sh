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
  exec sudo \
    --preserve-env=PATH \
    --preserve-env=LD_LIBRARY_PATH \
    --preserve-env=PYTHONPATH \
    --preserve-env=OMP_NUM_THREADS \
    --preserve-env=HDF5_USE_FILE_LOCKING \
    --preserve-env=LAL_DATA_PATH \
    -H -u root "$@"
fi
