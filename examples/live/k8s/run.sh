#!/bin/bash

# example/test of running PyCBC Live on simulated data

set -e

export OMP_NUM_THREADS=4
export HDF5_USE_FILE_LOCKING="FALSE"

TMP_DIR=./tmp
mkdir -p "${TMP_DIR}"

TEMPLATE_BANK="${TMP_DIR}/template_bank.hdf"
TEMPLATE_BANK_FULL="${TMP_DIR}/template_bank_full.hdf"
TEMPLATE_BANK_PREFIX="${TMP_DIR}/template_bank_"
STRAIN_DIR="${TMP_DIR}/strain"
FIT_COEFFS_H1="${TMP_DIR}/H1-fit_coeffs.hdf"
FIT_COEFFS_L1="${TMP_DIR}/L1-fit_coeffs.hdf"
FIT_COEFFS_V1="${TMP_DIR}/V1-fit_coeffs.hdf"
INJECTIONS_FILE="${TMP_DIR}/injections.hdf"
SINGLE_SIG_FITS_FILE="${TMP_DIR}/single_significance_fits.hdf"
STAT_HL="${TMP_DIR}/statHL.hdf"
STAT_HV="${TMP_DIR}/statHV.hdf"
STAT_LV="${TMP_DIR}/statLV.hdf"
STAT_HLV="${TMP_DIR}/statHLV.hdf"

gps_start_time=1272790000
gps_end_time=1272790512
f_min=18

# delete old outputs if they exist
rm -rf ./output


echo -e "\\n\\n>> [`date`] Running PyCBC Live"

MPI_NP=${MPI_NP:-2}
MPI_BIND=${MPI_BIND:---bind-to none}

MPI_OPTS=()
if [[ -n "${MPI_HOST_ARGS:-}" ]]; then
    MPI_OPTS+=(${MPI_HOST_ARGS})
fi
MPI_OPTS+=(-np "${MPI_NP}")
if [[ -n "${MPI_BIND:-}" ]]; then
    MPI_OPTS+=(${MPI_BIND})
fi
MPI_OPTS+=("--display-allocation")
if [[ -n "${MPI_EXTRA_FLAGS:-}" ]]; then
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
)

mpirun \
    "${MPI_OPTS[@]}" \
    "${MPI_EXPORT_ARGS[@]}" \
    python -m mpi4py "$(command -v pycbc_live)" \
--bank-file "${TEMPLATE_BANK}" \
--sample-rate 2048 \
--enable-bank-start-frequency \
--low-frequency-cutoff ${f_min} \
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
--min-psd-abort-distance 20 \
--psd-abort-difference .15 \
--psd-recalculate-difference .01 \
--psd-inverse-length 3.5 \
--psd-segment-length 4 \
--trim-padding .5 \
--store-psd \
--increment-update-cache \
    H1:"${STRAIN_DIR}/H1" \
    L1:"${STRAIN_DIR}/L1" \
    V1:"${STRAIN_DIR}/V1" \
--frame-src \
    H1:"${STRAIN_DIR}/H1"/* \
    L1:"${STRAIN_DIR}/L1"/* \
    V1:"${STRAIN_DIR}/V1"/* \
--frame-read-timeout 10 \
--channel-name \
    H1:SIMULATED_STRAIN \
    L1:SIMULATED_STRAIN \
    V1:SIMULATED_STRAIN \
--processing-scheme cpu:4 \
--fftw-measure-level 0 \
--fftw-threads-backend openmp \
--increment 8 \
--max-batch-size 16777216 \
--output-path output \
--day-hour-output-prefix \
--sngl-ranking newsnr_sgveto_psdvar_threshold \
--ranking-statistic \
  exp_fit \
--statistic-features \
  phasetd \
  sensitive_volume \
  normalize_fit_rate \
--statistic-keywords \
  alpha_below_thresh:6 \
--statistic-files \
  "${STAT_HL}" \
  "${STAT_HV}" \
  "${STAT_LV}" \
  "${FIT_COEFFS_H1}" \
  "${FIT_COEFFS_L1}" \
  "${FIT_COEFFS_V1}" \
--sgchisq-snr-threshold 4 \
--sgchisq-locations "mtotal>40:20-30,20-45,20-60,20-75,20-90,20-105,20-120" \
--enable-background-estimation \
--background-ifar-limit 100 \
--timeslide-interval 0.1 \
--pvalue-combination-livetime 0.0005 \
--ifar-double-followup-threshold 0.0001 \
--ifar-upload-threshold 0.0001 \
--round-start-time 4 \
--start-time $gps_start_time \
--end-time $gps_end_time \
--src-class-mchirp-to-delta 0.01 \
--src-class-eff-to-lum-distance 0.74899 \
--src-class-lum-distance-to-delta -0.51557 -0.32195 \
--run-snr-optimization \
--snr-opt-extra-opts \
    "--snr-opt-method differential_evolution \
    --snr-opt-di-maxiter 50 \
    --snr-opt-di-popsize 100 \
    --snr-opt-include-candidate " \
--sngl-ifar-est-dist conservative \
--single-ranking-threshold 9 \
--single-duration-threshold 7 \
--single-reduced-chisq-threshold 2 \
--single-fit-file "${SINGLE_SIG_FITS_FILE}" \
--single-maximum-ifar 100 \
--psd-variation \
--verbose

# If you would like to use the pso optimizer, change --optimizer to pso
#  and include these arguments while removing other optimizer args.
#  You will need to install the pyswarms package into your environment.
# --snr-opt-extra-opts \
#   "--snr-opt-method pso \
#   --snr-opt-pso-iters 5 \
#   --snr-opt-pso-particles 250 \
#   --snr-opt-pso-c1 0.5 \
#   --snr-opt-pso-c2 2.0 \
#   --snr-opt-pso-w 0.01 \
#   --snr-opt-include-candidate " \

# note that, at this point, some SNR optimization processes may still be
# running, so the checks below may ignore their results

# cat the logs of pycbc_optimize_snr so we can check them
for opt_snr_log in `find output -type f -name optimize_snr.log | sort`
do
    echo -e "\\n\\n>> [`date`] Showing log of SNR optimizer, ${opt_snr_log}"
    cat ${opt_snr_log}
done

echo -e "\\n\\n>> [`date`] Checking results"
./check_results.py \
    --gps-start ${gps_start_time} \
    --gps-end ${gps_end_time} \
    --f-min ${f_min} \
    --bank "${TEMPLATE_BANK}" \
    --injections "${INJECTIONS_FILE}" \
    --detectors H1 L1 V1

# echo -e "\\n\\n>> [`date`] Running Bayestar"
# for XMLFIL in `find output -type f -name \*.xml\* | sort`
# do
#     pushd `dirname ${XMLFIL}`
#     bayestar-localize-coincs --f-low ${f_min} `basename ${XMLFIL}` `basename ${XMLFIL}`
#     test -f 0.fits
#     popd
# done
