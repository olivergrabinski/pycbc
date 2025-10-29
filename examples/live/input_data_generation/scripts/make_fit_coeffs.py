"""
Makes files which can be used as the fit_coeffs statistic.
These are not of any scientific use, but the code will accept them
and run properly

The location of the template_bank should be given as argument
Example: python make_fit_coeffs.py template_bank.hdf
"""

import os
import sys
import numpy as np
from pycbc.io.hdf import HFile

if len(sys.argv) < 2:
    raise SystemExit("Usage: python make_fit_coeffs.py <template_bank.hdf>")

output_dir = os.environ.get("FIT_COEFFS_DIR", ".")
os.makedirs(output_dir, exist_ok=True)

# Get number of templates from bank file
with HFile(sys.argv[1], "r") as bankf:
    n_templates = bankf["mass1"].size

for ifo in ["H1", "L1", "V1"]:
    output_path = os.path.join(output_dir, f"{ifo}-fit_coeffs.hdf")
    with HFile(output_path, "w") as fits_f:
        fits_f.attrs["analysis_time"] = 430000
        fits_f.attrs["ifo"] = ifo
        fits_f.attrs["stat"] = f"{ifo}-fit_coeffs"
        fits_f.attrs["stat_threshold"] = 5

        fits_f["count_above_thresh"] = np.ones(n_templates) * 100
        fits_f["count_in_template"] = np.ones(n_templates) * 20000
        fits_f["fit_coeff"] = np.ones(n_templates) * 5.5
        fits_f["median_sigma"] = np.ones(n_templates) * 5800
        fits_f["template_id"] = np.arange(n_templates)
