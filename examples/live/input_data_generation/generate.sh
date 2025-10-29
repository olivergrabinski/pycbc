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


# test if there is a template bank. If not, make one

if [[ ! -f "${TEMPLATE_BANK}" ]]
then
    echo -e "\\n\\n>> [`date`] Making template bank"
    curl \
        --remote-name \
        --silent \
        --show-error \
        https://raw.githubusercontent.com/gwastro/pycbc-config/710dbfd3590bd93d7679d7822da59fcb6b6fac0f/O2/bank/H1L1-HYPERBANK_SEOBNRv4v2_VARFLOW_THORNE-1163174417-604800.xml.gz

    pycbc_coinc_bank2hdf \
        --bank-file H1L1-HYPERBANK_SEOBNRv4v2_VARFLOW_THORNE-1163174417-604800.xml.gz \
        --output-file "${TEMPLATE_BANK_FULL}"

    rm -f H1L1-HYPERBANK_SEOBNRv4v2_VARFLOW_THORNE-1163174417-604800.xml.gz

    pycbc_hdf5_splitbank \
        --bank-file "${TEMPLATE_BANK_FULL}" \
        --output-prefix "${TEMPLATE_BANK_PREFIX}" \
        --random-sort \
        --random-seed 831486 \
        --templates-per-bank 50

    mv "${TEMPLATE_BANK_PREFIX}"0.hdf "${TEMPLATE_BANK}"
    rm -f "${TEMPLATE_BANK_PREFIX}"*.hdf
else
    echo -e "\\n\\n>> [`date`] Pre-existing template bank found"
fi

# test if there is a single fits file. If not, make a representative one
if [[ ! -f "${SINGLE_SIG_FITS_FILE}" ]]
then
    echo -e "\\n\\n>> [`date`] Making single significance fits file"
    python make_singles_significance_fits.py "${SINGLE_SIG_FITS_FILE}"
else
    echo -e "\\n\\n>> [`date`] Pre-existing single significance fits file found"
fi

# test if there are fit_coeffs files for each detector.
# If not, make some representative ones
if [[ ! -f "${FIT_COEFFS_H1}" || ! -f "${FIT_COEFFS_L1}" || ! -f "${FIT_COEFFS_V1}" ]]
then
    echo -e "\\n\\n>> [`date`] Making fit coefficient files"
    FIT_COEFFS_DIR="${TMP_DIR}" python make_fit_coeffs.py "${TEMPLATE_BANK}"
else
    echo -e "\\n\\n>> [`date`] All needed fit coeffs files found"
fi

# test if there is a injection file.
# If not, make one and delete any existing strain

if [[ -f "${INJECTIONS_FILE}" ]]
then
    echo -e "\\n\\n>> [`date`] Pre-existing injections found"
else
    echo -e "\\n\\n>> [`date`] Generating injections"

    rm -rf "${STRAIN_DIR}"

    ./generate_injections.py "${INJECTIONS_FILE}"
fi


# test if strain files exist. If they don't, make them

if [[ ! -d "${STRAIN_DIR}" ]]
then
    echo -e "\\n\\n>> [`date`] Generating simulated strain"

    function simulate_strain { # detector PSD_model random_seed
        mkdir -p "${STRAIN_DIR}/$1"

        out_path="${STRAIN_DIR}/$1/$1-SIMULATED_STRAIN-{start}-{duration}.gwf"

        pycbc_condition_strain \
            --fake-strain $2 \
            --fake-strain-seed $3 \
            --output-strain-file $out_path \
            --gps-start-time $gps_start_time \
            --gps-end-time $4 \
            --sample-rate 16384 \
            --low-frequency-cutoff 10 \
            --channel-name $1:SIMULATED_STRAIN \
            --frame-duration 32 \
            --injection-file "${INJECTIONS_FILE}"
    }
    # L1 ends 32s later, so that we can inject in single-detector time
    simulate_strain H1 aLIGOMidLowSensitivityP1200087 1234 $((gps_end_time - 32))
    simulate_strain L1 aLIGOMidLowSensitivityP1200087 2345 $gps_end_time
    simulate_strain V1 AdVEarlyLowSensitivityP1200087 3456 $((gps_end_time - 32))

else
    echo -e "\\n\\n>> [`date`] Pre-existing strain data found"
fi


# make phase-time-amplitude histogram files, if needed

if [[ ! -f "${STAT_HL}" ]]
then
    echo -e "\\n\\n>> [`date`] Making phase-time-amplitude files"

    STAT_OUTPUT_DIR="${TMP_DIR}" bash ./stats.sh
else
    echo -e "\\n\\n>> [`date`] Pre-existing phase-time-amplitude files found"
fi
