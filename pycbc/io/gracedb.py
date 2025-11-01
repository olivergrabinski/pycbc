"""
Class and function for use in dealing with GraceDB uploads
"""

import logging
import os
import numpy
import json
import copy
from multiprocessing.dummy import threading
from urllib.parse import urljoin

import requests

import lal
from igwn_ligolw import ligolw
from igwn_ligolw import lsctables
from igwn_ligolw import utils as ligolw_utils

import pycbc
from pycbc import version as pycbc_version
from pycbc import pnutils
from pycbc.io.ligolw import (
    return_empty_sngl,
    create_process_table,
    make_psd_xmldoc,
    snr_series_to_xml,
)
from pycbc.mchirp_area import calc_probabilities

logger = logging.getLogger("pycbc.io.gracedb")


class CandidateForGraceDB(object):
    """This class provides an interface for uploading candidates to GraceDB."""

    def __init__(self, coinc_ifos, ifos, coinc_results, **kwargs):
        """Initialize a representation of a zerolag candidate for upload to
        GraceDB.

        Parameters
        ----------
        coinc_ifos: list of strs
            A list of the originally triggered ifos with SNR above threshold
            for this candidate, before possible significance followups.
        ifos: list of strs
            A list of ifos which may have triggers identified in coinc_results
            for this candidate: ifos potentially contributing to significance
        coinc_results: dict of values
            A dictionary of values. The format is defined in
            `pycbc/events/coinc.py` and matches the on-disk representation in
            the hdf file for this time.
        psds: dict of FrequencySeries
            Dictionary providing PSD estimates for all detectors observing.
        low_frequency_cutoff: float
            Minimum valid frequency for the PSD estimates.
        high_frequency_cutoff: float, optional
            Maximum frequency considered for the PSD estimates. Default None.
        skyloc_data: dict of dicts, optional
            Dictionary providing SNR time series for each detector, to be used
            in sky localization with BAYESTAR. The format should be
            `skyloc_data['H1']['snr_series']`. More detectors can be present
            than in `ifos`; if so, extra detectors will only be used for sky
            localization.
        channel_names: dict of strings, optional
            Strain channel names for each detector. Will be recorded in the
            `sngl_inspiral` table.
        padata: PAstroData instance
            Organizes info relevant to the astrophysical probability of the
            candidate.
        mc_area_args: dict of dicts, optional
            Dictionary providing arguments to be used in source probability
            estimation with `pycbc/mchirp_area.py`.
        """
        self.coinc_results = coinc_results
        self.psds = kwargs["psds"]
        self.basename = None
        self.graceid = None
        if kwargs.get("gracedb"):
            self.gracedb = kwargs["gracedb"]

        # Determine if the candidate should be marked as HWINJ
        self.is_hardware_injection = "HWINJ" in coinc_results and coinc_results["HWINJ"]

        # We may need to apply a time offset for premerger search
        self.time_offset = 0
        rtoff = f"foreground/{ifos[0]}/time_offset"
        if rtoff in coinc_results:
            self.time_offset = coinc_results[rtoff]

        # Check for ifos with SNR peaks in coinc_results
        self.et_ifos = [i for i in ifos if f"foreground/{i}/end_time" in coinc_results]

        if "skyloc_data" in kwargs:
            sld = kwargs["skyloc_data"]
            assert len({sld[ifo]["snr_series"].delta_t for ifo in sld}) == 1, (
                "delta_t for all ifos do not match"
            )
            snr_ifos = sld.keys()  # Ifos with SNR time series calculated
            self.snr_series = {ifo: sld[ifo]["snr_series"] for ifo in snr_ifos}
            # Extra ifos have SNR time series but not sngl inspiral triggers

            for ifo in snr_ifos:
                # Ifos used for sky loc must have a PSD
                assert ifo in self.psds
                self.snr_series[ifo].start_time += self.time_offset
        else:
            self.snr_series = None
            snr_ifos = self.et_ifos

        # Set up the bare structure of the xml document
        outdoc = ligolw.Document()
        outdoc.appendChild(ligolw.LIGO_LW())

        proc_id = create_process_table(
            outdoc, program_name="pycbc", detectors=snr_ifos
        ).process_id

        # Set up coinc_definer table
        coinc_def_table = lsctables.CoincDefTable.new()
        coinc_def_id = lsctables.CoincDefID(0)
        coinc_def_row = lsctables.CoincDef()
        coinc_def_row.search = "inspiral"
        coinc_def_row.description = "sngl_inspiral<-->sngl_inspiral coincs"
        coinc_def_row.coinc_def_id = coinc_def_id
        coinc_def_row.search_coinc_type = 0
        coinc_def_table.append(coinc_def_row)
        outdoc.childNodes[0].appendChild(coinc_def_table)

        # Set up coinc inspiral and coinc event tables
        coinc_id = lsctables.CoincID(0)
        coinc_event_table = lsctables.CoincTable.new()
        coinc_event_row = lsctables.Coinc()
        coinc_event_row.coinc_def_id = coinc_def_id
        coinc_event_row.nevents = len(snr_ifos)
        coinc_event_row.instruments = ",".join(snr_ifos)
        coinc_event_row.time_slide_id = lsctables.TimeSlideID(0)
        coinc_event_row.process_id = proc_id
        coinc_event_row.coinc_event_id = coinc_id
        if "foreground/stat" in coinc_results:
            coinc_event_row.likelihood = coinc_results["foreground/stat"]
        else:
            coinc_event_row.likelihood = 0.0
        coinc_event_table.append(coinc_event_row)
        outdoc.childNodes[0].appendChild(coinc_event_table)

        # Set up sngls
        sngl_inspiral_table = lsctables.SnglInspiralTable.new()
        coinc_event_map_table = lsctables.CoincMapTable.new()

        # Marker variable recording template info from a valid sngl trigger
        sngl_populated = None
        network_snrsq = 0
        for sngl_id, ifo in enumerate(snr_ifos):
            sngl = return_empty_sngl(nones=True)
            sngl.event_id = lsctables.SnglInspiralID(sngl_id)
            sngl.process_id = proc_id
            sngl.ifo = ifo
            names = [
                n.split("/")[-1] for n in coinc_results if f"foreground/{ifo}" in n
            ]
            for name in names:
                val = coinc_results[f"foreground/{ifo}/{name}"]
                if name == "end_time":
                    val += self.time_offset
                    sngl.end = lal.LIGOTimeGPS(val)
                else:
                    # Sngl inspirals have a restricted set of attributes
                    try:
                        setattr(sngl, name, val)
                    except AttributeError:
                        pass
            if sngl.mass1 and sngl.mass2:
                sngl.mtotal, sngl.eta = pnutils.mass1_mass2_to_mtotal_eta(
                    sngl.mass1, sngl.mass2
                )
                sngl.mchirp, _ = pnutils.mass1_mass2_to_mchirp_eta(
                    sngl.mass1, sngl.mass2
                )
                sngl_populated = sngl
            if sngl.snr:
                sngl.eff_distance = sngl.sigmasq**0.5 / sngl.snr
                network_snrsq += sngl.snr**2.0
            if "channel_names" in kwargs and ifo in kwargs["channel_names"]:
                sngl.channel = kwargs["channel_names"][ifo]
            sngl_inspiral_table.append(sngl)

            # Set up coinc_map entry
            coinc_map_row = lsctables.CoincMap()
            coinc_map_row.table_name = "sngl_inspiral"
            coinc_map_row.coinc_event_id = coinc_id
            coinc_map_row.event_id = sngl.event_id
            coinc_event_map_table.append(coinc_map_row)

            if self.snr_series is not None:
                snr_series_to_xml(self.snr_series[ifo], outdoc, sngl.event_id)

        # Set merger time to the mean of trigger peaks over coinc_results ifos
        self.merger_time = (
            numpy.mean(
                [coinc_results[f"foreground/{ifo}/end_time"] for ifo in self.et_ifos]
            )
            + self.time_offset
        )

        outdoc.childNodes[0].appendChild(coinc_event_map_table)
        outdoc.childNodes[0].appendChild(sngl_inspiral_table)

        # Set up the coinc inspiral table
        coinc_inspiral_table = lsctables.CoincInspiralTable.new()
        coinc_inspiral_row = lsctables.CoincInspiral()
        # This seems to be used as FAP, which should not be in gracedb
        coinc_inspiral_row.false_alarm_rate = 0.0
        coinc_inspiral_row.minimum_duration = 0.0
        coinc_inspiral_row.instruments = tuple(snr_ifos)
        coinc_inspiral_row.coinc_event_id = coinc_id
        coinc_inspiral_row.mchirp = sngl_populated.mchirp
        coinc_inspiral_row.mass = sngl_populated.mtotal
        coinc_inspiral_row.end_time = sngl_populated.end_time
        coinc_inspiral_row.end_time_ns = sngl_populated.end_time_ns
        coinc_inspiral_row.snr = network_snrsq**0.5
        far = 1.0 / (lal.YRJUL_SI * coinc_results["foreground/ifar"])
        coinc_inspiral_row.combined_far = far
        coinc_inspiral_table.append(coinc_inspiral_row)
        outdoc.childNodes[0].appendChild(coinc_inspiral_table)

        # Append the PSDs
        psds_lal = {}
        for ifo, psd in self.psds.items():
            kmin = int(kwargs["low_frequency_cutoff"] / psd.delta_f)
            fseries = lal.CreateREAL8FrequencySeries(
                "psd",
                psd.epoch,
                kwargs["low_frequency_cutoff"],
                psd.delta_f,
                lal.StrainUnit**2 / lal.HertzUnit,
                len(psd) - kmin,
            )
            fseries.data.data = (
                psd.numpy()[kmin:].astype(numpy.float64) / pycbc.DYN_RANGE_FAC**2.0
            )
            psds_lal[ifo] = fseries
        make_psd_xmldoc(psds_lal, outdoc)

        # P astro calculation
        if "padata" in kwargs:
            if "p_terr" in kwargs:
                raise RuntimeError(
                    "Both p_astro calculation data and a "
                    "previously calculated p_terr value were provided, this "
                    "doesn't make sense!"
                )
            assert len(coinc_ifos) < 3, f"p_astro can't handle {coinc_ifos} coinc ifos!"
            trigger_data = {
                "mass1": sngl_populated.mass1,
                "mass2": sngl_populated.mass2,
                "spin1z": sngl_populated.spin1z,
                "spin2z": sngl_populated.spin2z,
                "network_snr": network_snrsq**0.5,
                "far": far,
                "triggered": coinc_ifos,
                # Consider all ifos potentially relevant to detection,
                # ignore those that only contribute to sky loc
                "sensitive": self.et_ifos,
            }
            horizons = {i: self.psds[i].dist for i in self.et_ifos}
            self.p_astro, self.p_terr = kwargs["padata"].do_pastro_calc(
                trigger_data, horizons
            )
        elif "p_terr" in kwargs:
            self.p_astro, self.p_terr = 1 - kwargs["p_terr"], kwargs["p_terr"]
        else:
            self.p_astro, self.p_terr = None, None

        # Source probabilities and hasmassgap estimation
        self.probabilities = None
        self.hasmassgap = None
        if "mc_area_args" in kwargs:
            eff_distances = [sngl.eff_distance for sngl in sngl_inspiral_table]
            self.probabilities = calc_probabilities(
                coinc_inspiral_row.mchirp,
                coinc_inspiral_row.snr,
                min(eff_distances),
                kwargs["mc_area_args"],
            )
            if "embright_mg_max" in kwargs["mc_area_args"]:
                hasmg_args = copy.deepcopy(kwargs["mc_area_args"])
                hasmg_args["mass_gap"] = True
                hasmg_args["mass_bdary"]["gap_max"] = kwargs["mc_area_args"][
                    "embright_mg_max"
                ]
                self.hasmassgap = calc_probabilities(
                    coinc_inspiral_row.mchirp,
                    coinc_inspiral_row.snr,
                    min(eff_distances),
                    hasmg_args,
                )["Mass Gap"]

        # Combine p astro and source probs
        if self.p_astro is not None and self.probabilities is not None:
            self.astro_probs = {
                cl: pr * self.p_astro for cl, pr in self.probabilities.items()
            }
            self.astro_probs["Terrestrial"] = self.p_terr
        else:
            self.astro_probs = None

        self.outdoc = outdoc
        self.time = sngl_populated.end

    def save(self, fname):
        """Write a file representing this candidate in a LIGOLW XML format
        compatible with GraceDB.

        Parameters
        ----------
        fname: str
            Name of file to write to disk.
        """
        kwargs = {}
        if threading.current_thread() is not threading.main_thread():
            # avoid an error due to no ability to do signal handling in threads
            kwargs["trap_signals"] = None
        ligolw_utils.write_filename(self.outdoc, fname, compress="auto", **kwargs)

        save_dir = os.path.dirname(fname)
        # Save EMBright properties info as json
        if self.hasmassgap is not None:
            self.embright_file = os.path.join(save_dir, "pycbc.em_bright.json")
            with open(self.embright_file, "w") as embrightf:
                json.dump({"HasMassGap": self.hasmassgap}, embrightf)
            logger.info("EM Bright file saved as %s", self.embright_file)

        # Save multi-cpt p astro as json
        if self.astro_probs is not None:
            self.multipa_file = os.path.join(save_dir, "pycbc.p_astro.json")
            with open(self.multipa_file, "w") as multipaf:
                json.dump(self.astro_probs, multipaf)
            logger.info("Multi p_astro file saved as %s", self.multipa_file)

        # Save source probabilities in a json file
        if self.probabilities is not None:
            self.prob_file = os.path.join(save_dir, "src_probs.json")
            with open(self.prob_file, "w") as probf:
                json.dump(self.probabilities, probf)
            logger.info("Source probabilities file saved as %s", self.prob_file)
            # Don't save any other files!
            return

        # Save p astro / p terr as json
        if self.p_astro is not None:
            self.pastro_file = os.path.join(save_dir, "pa_pterr.json")
            with open(self.pastro_file, "w") as pastrof:
                json.dump({"p_astro": self.p_astro, "p_terr": self.p_terr}, pastrof)
            logger.info("P_astro file saved as %s", self.pastro_file)

    def upload(
        self,
        fname,
        gracedb_server=None,
        testing=True,
        extra_strings=None,
        search="AllSky",
        labels=None,
        **kwargs,
    ):
        """Upload this candidate to a GraceDB-compatible service via BASIC auth.

        Parameters
        ----------
        fname: str
            The name to give the xml file associated with this trigger
        gracedb_server: string, optional
            URL to the GraceDB web API service for uploading the event.
            If omitted, ``PYCBC_GRACEDB_URL`` (if set) will be used.
        testing: bool
            Switch to determine if the upload should be sent to gracedb as a
            test trigger (True) or a production trigger (False).
        search: str
            String going into the "search" field of the GraceDB event.
        labels: list
            Optional list of labels to tag the new event with.
        basic_auth: tuple(str, str) keyword-only via kwargs
            Provide the username and password to authenticate with the target
            service using HTTP Basic authentication. If omitted, the upload
            will look for ``PYCBC_GRACEDB_USERNAME``/``PYCBC_GRACEDB_PASSWORD``
            (or ``GRACEDB_USERNAME``/``GRACEDB_PASSWORD``) in the environment.
        kwargs: named keyword arguments
            Supported keywords:
              * ``basic_auth``: alias of the argument above.
              * ``timeout``: request timeout in seconds (default 30).
        """

        if fname.endswith(".xml.gz"):
            self.basename = fname.replace(".xml.gz", "")
        elif fname.endswith(".xml"):
            self.basename = fname.replace(".xml", "")
        else:
            raise ValueError(
                "Upload filename must end in .xml or .xml.gz, got %s" % fname
            )

        # First make sure the event is saved on disk
        # as GraceDB operations can fail later
        self.save(fname)

        # hardware injections need to be maked with the INJ tag
        if self.is_hardware_injection:
            labels = (labels or []) + ["INJ"]

        basic_auth = kwargs.pop("basic_auth", kwargs.pop("auth", None))
        timeout = kwargs.pop("timeout", 30)
        if kwargs:
            logger.debug(
                "Ignoring unsupported upload kwargs: %s", ", ".join(sorted(kwargs))
            )

        if basic_auth is None:
            env_user = os.environ.get("PYCBC_GRACEDB_USERNAME") or os.environ.get(
                "GRACEDB_USERNAME"
            )
            env_pass = os.environ.get("PYCBC_GRACEDB_PASSWORD") or os.environ.get(
                "GRACEDB_PASSWORD"
            )
            if env_user and env_pass:
                basic_auth = (env_user, env_pass)

        if gracedb_server is None:
            gracedb_server = os.environ.get("PYCBC_GRACEDB_URL")

        if gracedb_server is None:
            raise ValueError("gracedb_server must be provided for upload")
        if basic_auth is None:
            raise ValueError("basic_auth must be provided for upload")
        if not isinstance(basic_auth, (tuple, list)) or len(basic_auth) != 2:
            raise ValueError("basic_auth must be a (username, password) tuple")

        session = requests.Session()
        session.auth = tuple(basic_auth)
        service_url = gracedb_server.rstrip("/") + "/"

        # create GraceDB event using HTTP Basic authentication
        logger.info("Uploading %s to GraceDB", fname)
        group = "Test" if testing else "CBC"
        self.graceid = None

        data = {"group": group, "pipeline": "pycbc", "search": search}
        if labels:
            data["labels"] = ",".join(labels)

        try:
            with open(fname, "rb") as event_file:
                response = session.post(
                    urljoin(service_url, "events/"),
                    files={"eventFile": event_file},
                    data=data,
                    timeout=timeout,
                )
        except Exception as exc:
            logger.error("Failed to create GraceDB event via basic auth")
            logger.error(str(exc))
            return None

        if not response.ok:
            logger.error(
                "Failed to create GraceDB event (HTTP %s)", response.status_code
            )
            try:
                logger.error(response.text)
            except Exception:
                pass
            return None

        try:
            payload = response.json()
        except ValueError:
            logger.error("GraceDB response was not valid JSON")
            return None

        self.graceid = payload.get("graceid")
        if self.graceid:
            logger.info("Uploaded event %s", self.graceid)
        else:
            logger.error("GraceDB response did not include a graceid")

        return self.graceid


def gracedb_tag_with_version(gracedb, event_id):
    """Add a GraceDB log entry reporting PyCBC's version and install location."""
    version_str = "Using PyCBC version {}{} at {}"
    version_str = version_str.format(
        pycbc_version.version,
        " (release)" if pycbc_version.release else "",
        os.path.dirname(pycbc.__file__),
    )
    gracedb.write_log(event_id, version_str)


__all__ = [
    "CandidateForGraceDB",
    "gracedb_tag_with_version",
]
