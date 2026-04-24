#!/bin/bash

# PyCBC Live O4 full-bandwidth runner for Kubernetes.
#
# This is intentionally a k8s-specific adaptation of the production CIT
# full-bandwidth configuration. It expects O4 configuration products and
# replay/static frame data to be mounted into the pod.

set -euo pipefail

export OMP_NUM_THREADS="${OMP_NUM_THREADS:-4}"
export HDF5_USE_FILE_LOCKING="${HDF5_USE_FILE_LOCKING:-FALSE}"

CONF_DIR="${CONF_DIR:-/workspace/o4-config}"
LOCAL_DIR="${LOCAL_DIR:-/workspace/o4-output}"
FRAME_DIR="${FRAME_DIR:-/workspace/frames}"
FRAME_READ_TIMEOUT="${FRAME_READ_TIMEOUT:-50}"
GRACEDB_SERVER="${GRACEDB_SERVER:-https://gracedb-playground.ligo.org/api/}"
ENABLE_GRACEDB_UPLOAD="${ENABLE_GRACEDB_UPLOAD:-false}"
ENABLE_PRODUCTION_GRACEDB_UPLOAD="${ENABLE_PRODUCTION_GRACEDB_UPLOAD:-false}"

BANK_FILE="${BANK_FILE:-${CONF_DIR}/bank/O4_DESIGN_OPT_FLOW_HYBRID_BANK_O3_CONFIG.hdf}"
FFTW_WISDOM_FILE="${FFTW_WISDOM_FILE:-${CONF_DIR}/cit/fftw_wisdom}"
P_ASTRO_SPEC="${P_ASTRO_SPEC:-${CONF_DIR}/p_astro_spec.json}"
PTA_H1L1="${PTA_H1L1:-${CONF_DIR}/pta_files/H1L1-PTA_HISTOGRAM_O4.hdf}"
PTA_H1V1="${PTA_H1V1:-${CONF_DIR}/pta_files/H1V1-PTA_HISTOGRAM_O4.hdf}"
PTA_L1V1="${PTA_L1V1:-${CONF_DIR}/pta_files/L1V1-PTA_HISTOGRAM_O4.hdf}"

H1_FRAME_DIR="${H1_FRAME_DIR:-${FRAME_DIR}/H1_O4LLPIC}"
L1_FRAME_DIR="${L1_FRAME_DIR:-${FRAME_DIR}/L1_O4LLPIC}"
V1_FRAME_DIR="${V1_FRAME_DIR:-${FRAME_DIR}/V1_O4LLPIC}"

mkdir -p "${LOCAL_DIR}/triggers"

required_files=(
    "${BANK_FILE}"
    "${FFTW_WISDOM_FILE}"
    "${P_ASTRO_SPEC}"
    "${PTA_H1L1}"
    "${PTA_H1V1}"
    "${PTA_L1V1}"
)

for path in "${required_files[@]}"; do
    if [[ ! -f "${path}" ]]; then
        >&2 echo "Required file is missing: ${path}"
        exit 1
    fi
done

for path in "${H1_FRAME_DIR}" "${L1_FRAME_DIR}" "${V1_FRAME_DIR}"; do
    if [[ ! -d "${path}" ]]; then
        >&2 echo "Required frame directory is missing: ${path}"
        exit 1
    fi
done

shopt -s nullglob
h1_frames=("${H1_FRAME_DIR}"/*)
l1_frames=("${L1_FRAME_DIR}"/*)
v1_frames=("${V1_FRAME_DIR}"/*)
shopt -u nullglob

if (( ${#h1_frames[@]} == 0 || ${#l1_frames[@]} == 0 || ${#v1_frames[@]} == 0 )); then
    >&2 echo "Frame directories must contain replay/static frame files for H1, L1, and V1."
    exit 1
fi

MPI_NP="${MPI_NP:-3}"
MPI_BIND="${MPI_BIND:---bind-to none}"

MPI_OPTS=()
if [[ -n "${MPI_HOST_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    MPI_OPTS+=(${MPI_HOST_ARGS})
fi
MPI_OPTS+=(-np "${MPI_NP}")
if [[ -n "${MPI_BIND}" ]]; then
    # shellcheck disable=SC2206
    MPI_OPTS+=(${MPI_BIND})
fi
MPI_OPTS+=(--display-allocation)
if [[ -n "${MPI_EXTRA_FLAGS:-}" ]]; then
    # shellcheck disable=SC2206
    MPI_OPTS+=(${MPI_EXTRA_FLAGS})
else
    MPI_OPTS+=(--display-map --report-bindings)
fi

MPI_EXPORT_ARGS=(
    -x PYTHONPATH
    -x LD_LIBRARY_PATH
    -x OMP_NUM_THREADS
    -x VIRTUAL_ENV
    -x PATH
    -x HDF5_USE_FILE_LOCKING
    -x LAL_DATA_PATH
    -x BEARER_TOKEN_FILE
    -x X509_USER_PROXY
)

GRACEDB_ARGS=()
if [[ "${ENABLE_GRACEDB_UPLOAD}" == "true" ]]; then
    GRACEDB_ARGS+=(--enable-gracedb-upload)
    GRACEDB_ARGS+=(--gracedb-server "${GRACEDB_SERVER}")
    if [[ "${ENABLE_PRODUCTION_GRACEDB_UPLOAD}" == "true" ]]; then
        GRACEDB_ARGS+=(--enable-production-gracedb-upload)
    fi
fi

echo -e "\\n\\n>> [$(date)] Running PyCBC Live O4 full-bandwidth on Kubernetes"
echo "CONF_DIR=${CONF_DIR}"
echo "LOCAL_DIR=${LOCAL_DIR}"
echo "FRAME_DIR=${FRAME_DIR}"
echo "MPI_NP=${MPI_NP}"
echo "ENABLE_GRACEDB_UPLOAD=${ENABLE_GRACEDB_UPLOAD}"

mpirun \
    "${MPI_OPTS[@]}" \
    "${MPI_EXPORT_ARGS[@]}" \
    python -m mpi4py "$(command -v pycbc_live)" \
--bank-file "${BANK_FILE}" \
--sample-rate 2048 \
--enable-bank-start-frequency \
--low-frequency-cutoff 17 \
--max-length 512 \
--approximant "SPAtmplt:mtotal<4" "SEOBNRv4_ROM:else" \
--chisq-bins "0.72*get_freq('fSEOBNRv4Peak',params.mass1,params.mass2,params.spin1z,params.spin2z)**0.7" \
--snr-abort-threshold 500 \
--snr-threshold 4.5 \
--newsnr-threshold 4.5 \
--max-triggers-in-batch 30 \
--store-loudest-index 50 \
--analysis-chunk 8 \
--autogating-threshold 50 \
--autogating-pad 0.5 \
--autogating-cluster 1 \
--autogating-width 0.25 \
--autogating-taper 0.25 \
--highpass-frequency 13 \
--highpass-bandwidth 5 \
--highpass-reduction 200 \
--psd-samples 30 \
--max-psd-abort-distance 600 \
--min-psd-abort-distance 68 \
--psd-abort-difference .15 \
--psd-recalculate-difference .01 \
--psd-inverse-length 3.5 \
--psd-segment-length 4 \
--trim-padding .5 \
--store-psd \
--increment-update-cache \
    H1:"${H1_FRAME_DIR}" \
    L1:"${L1_FRAME_DIR}" \
    V1:"${V1_FRAME_DIR}" \
--frame-src \
    H1:"${H1_FRAME_DIR}"/* \
    L1:"${L1_FRAME_DIR}"/* \
    V1:"${V1_FRAME_DIR}"/* \
--frame-read-timeout "${FRAME_READ_TIMEOUT}" \
--channel-name \
    H1:GDS-CALIB_STRAIN_CLEAN_INJ1_O4Replay \
    L1:GDS-CALIB_STRAIN_CLEAN_INJ1_O4Replay \
    V1:Hrec_hoft_16384Hz_INJ1_O4Replay \
--state-channel \
    H1:GDS-CALIB_STATE_VECTOR \
    L1:GDS-CALIB_STATE_VECTOR \
    V1:DQ_ANALYSIS_STATE_VECTOR \
--analyze-flags \
    H1:HOFT_OK,SCIENCE_INTENT \
    L1:HOFT_OK,SCIENCE_INTENT \
    V1:HOFT_OK,SCIENCE_INTENT,VIRGO_GOOD_DQ \
--data-quality-channel \
    H1:DMT-DQ_VECTOR \
    L1:DMT-DQ_VECTOR \
--data-quality-flags \
    H1:OMC_DCPD_ADC_OVERFLOW,ETMX_ESD_DAC_OVERFLOW,ETMY_ESD_DAC_OVERFLOW \
    L1:OMC_DCPD_ADC_OVERFLOW,ETMX_ESD_DAC_OVERFLOW,ETMY_ESD_DAC_OVERFLOW \
--idq-channel \
    H1:IDQ-FAP_OVL_10_2048 \
    L1:IDQ-FAP_OVL_10_2048 \
--idq-state-channel \
    H1:IDQ-OK_OVL_10_2048 \
    L1:IDQ-OK_OVL_10_2048 \
--idq-threshold 0.001 \
--idq-reweighting \
--data-quality-padding 1.0 \
--processing-scheme cpu:"${OMP_NUM_THREADS}" \
--fftw-measure-level 0 \
--fftw-input-float-wisdom-file "${FFTW_WISDOM_FILE}" \
--fftw-threads-backend openmp \
--increment 8 \
--max-batch-size 16777216 \
--output-path "${LOCAL_DIR}/triggers" \
--output-status "${LOCAL_DIR}/status.json" \
--day-hour-output-prefix \
--sngl-ranking newsnr_sgveto \
--ranking-statistic phasetd \
--statistic-files \
    "${PTA_H1L1}" \
    "${PTA_H1V1}" \
    "${PTA_L1V1}" \
--statistic-refresh-rate 3600 \
--sgchisq-snr-threshold 4 \
--sgchisq-locations "mtotal>40:20-30,20-45,20-60,20-75,20-90,20-105,20-120" \
--enable-background-estimation \
--background-ifar-limit 100 \
--timeslide-interval 0.1 \
--pvalue-combination-livetime 0.0005 \
--ifar-double-followup-threshold 0.0001 \
--ifar-upload-threshold 0.0002 \
--run-snr-optimization \
--snr-opt-extra-opts "--snr-opt-include-candidate " \
--src-class-mchirp-to-delta 0.01 \
--src-class-eff-to-lum-distance 0.74899 \
--src-class-lum-distance-to-delta -0.51557 -0.32195 \
--round-start-time 4 \
--p-astro-spec "${P_ASTRO_SPEC}" \
--skymap-only-ifos V1 \
"${GRACEDB_ARGS[@]}" \
--verbose
