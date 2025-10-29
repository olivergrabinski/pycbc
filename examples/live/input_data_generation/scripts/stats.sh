#!/bin/bash
set -e

OUTPUT_DIR="${STAT_OUTPUT_DIR:-.}"
mkdir -p "${OUTPUT_DIR}"

pycbc_dtphase \
--ifos H1 L1 \
--relative-sensitivities .7 1 \
--sample-size 200000 \
--snr-ratio 2.0 \
--seed 10 \
--output-file "${OUTPUT_DIR}/statHL.hdf" \
--smoothing-sigma 1 \
--verbose

pycbc_dtphase \
--ifos L1 V1 \
--relative-sensitivities 1 0.3 \
--sample-size 200000 \
--snr-ratio 2.0 \
--seed 10 \
--output-file "${OUTPUT_DIR}/statLV.hdf" \
--smoothing-sigma 1 \
--verbose

pycbc_dtphase \
--ifos H1 V1 \
--relative-sensitivities .7 .3 \
--sample-size 200000 \
--snr-ratio 2.0 \
--seed 10 \
--output-file "${OUTPUT_DIR}/statHV.hdf" \
--smoothing-sigma 1 \
--verbose


pycbc_dtphase \
--ifos H1 L1 V1 \
--relative-sensitivities .7 1 .3 \
--sample-size 50000 \
--timing-uncertainty .01 \
--snr-ratio 2.0 \
--seed 10 \
--output-file "${OUTPUT_DIR}/statHLV.hdf" \
--smoothing-sigma 1 \
--verbose
