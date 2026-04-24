# O4 Full-Bandwidth PyCBC Live on Kubernetes

This is a first-pass Kubernetes variant of the O4 full-bandwidth PyCBC Live
configuration. It keeps the working MPIJob pattern from `examples/live/k8s`
but runs the O4 production-style arguments against mounted replay/static frame
data. GraceDB upload is disabled by default.

## Files

- `run.sh`: k8s-specific O4 full-bandwidth launcher.
- `mpi-job.yaml`: MPIJob using the mpi-operator hostfile and mounted PVCs.
- `pvc.yaml`: PVCs for O4 config products and output products. Frame data is
  expected from an existing `igwn-lldd-frames` PVC.

## Expected Mount Layout

The MPIJob expects these paths in the containers:

```text
/workspace/o4-config/
  bank/O4_DESIGN_OPT_FLOW_HYBRID_BANK_O3_CONFIG.hdf
  cit/fftw_wisdom
  p_astro_spec.json
  pta_files/H1L1-PTA_HISTOGRAM_O4.hdf
  pta_files/H1V1-PTA_HISTOGRAM_O4.hdf
  pta_files/L1V1-PTA_HISTOGRAM_O4.hdf

/workspace/o4-output/

/workspace/frames/
  H1_O4LLPIC/*.gwf
  L1_O4LLPIC/*.gwf
  V1_O4LLPIC/*.gwf
```

This k8s runner is currently aligned to the
`examples/live/live-analysis/test/2025_llpic_o4_replay/full_bandwidth`
replay setup for frame layout and strain channel names.

The O4 config files can be seeded from
`examples/live/live-analysis/prod/o4/full_bandwidth`. The first-pass runner
uses `--ranking-statistic phasetd`, so it needs the PTA histogram files but
does not need the `*_fit_over_param_variable.hdf` or `*_idq_rerank_variable.hdf`
products required by the production `dq_phasetd_exp_fit_fgbg_norm` statistic.
Single-detector significance has also been disabled, so
`variable_significance_fits.hdf` is not required for this first-pass runner.

## Image Requirement

The MPIJob calls `/workspace/o4-full-bandwidth/run.sh`. Build an image that
includes this directory, or mount the script at that path with a ConfigMap.
The existing `examples/live/k8s/Dockerfile` only copies the top-level
`examples/live/k8s/run.sh`, so it needs to be extended or paired with a
ConfigMap before this MPIJob can run unchanged.

## Deploy

```sh
kubectl apply -f pvc.yaml
kubectl apply -f mpi-job.yaml
```

## Seed The PVCs

Assuming the Kubernetes namespace is `flare`, create the PVCs:

```sh
kubectl -n flare apply -f /Users/oliver/Developer/pycbc/examples/live/k8s/o4-full-bandwidth/pvc.yaml
```

Start temporary loader pods:

```sh
kubectl -n flare run o4-config-loader \
  --image=busybox:1.37 \
  --restart=Never \
  --overrides='
{
  "spec": {
    "containers": [
      {
        "name": "loader",
        "image": "busybox:1.37",
        "command": ["sh", "-c", "sleep 3600"],
        "volumeMounts": [
          {"name": "o4-config", "mountPath": "/mnt/o4-config"}
        ]
      }
    ],
    "volumes": [
      {
        "name": "o4-config",
        "persistentVolumeClaim": {"claimName": "o4-full-bandwidth-config"}
      }
    ]
  }
}'
```

```sh
kubectl -n flare run o4-output-loader \
  --image=busybox:1.37 \
  --restart=Never \
  --overrides='
{
  "spec": {
    "containers": [
      {
        "name": "loader",
        "image": "busybox:1.37",
        "command": ["sh", "-c", "sleep 3600"],
        "volumeMounts": [
          {"name": "o4-output", "mountPath": "/mnt/o4-output"}
        ]
      }
    ],
    "volumes": [
      {
        "name": "o4-output",
        "persistentVolumeClaim": {"claimName": "o4-full-bandwidth-output"}
      }
    ]
  }
}'
```

Create target directories on the config PVC:

```sh
kubectl -n flare exec o4-config-loader -- sh -c '
mkdir -p /mnt/o4-config/bank /mnt/o4-config/cit /mnt/o4-config/pta_files
'
```

Copy the required O4 config files into the config PVC:

```sh
kubectl -n flare cp /Users/oliver/Developer/pycbc/examples/live/live-analysis/prod/o4/full_bandwidth/bank/O4_DESIGN_OPT_FLOW_HYBRID_BANK_O3_CONFIG.hdf o4-config-loader:/mnt/o4-config/bank/O4_DESIGN_OPT_FLOW_HYBRID_BANK_O3_CONFIG.hdf
kubectl -n flare cp /Users/oliver/Developer/pycbc/examples/live/live-analysis/prod/o4/full_bandwidth/cit/fftw_wisdom o4-config-loader:/mnt/o4-config/cit/fftw_wisdom
kubectl -n flare cp /Users/oliver/Developer/pycbc/examples/live/live-analysis/prod/o4/full_bandwidth/p_astro_spec.json o4-config-loader:/mnt/o4-config/p_astro_spec.json
kubectl -n flare cp /Users/oliver/Developer/pycbc/examples/live/live-analysis/prod/o4/full_bandwidth/pta_files/H1L1-PTA_HISTOGRAM_O4.hdf o4-config-loader:/mnt/o4-config/pta_files/H1L1-PTA_HISTOGRAM_O4.hdf
kubectl -n flare cp /Users/oliver/Developer/pycbc/examples/live/live-analysis/prod/o4/full_bandwidth/pta_files/H1V1-PTA_HISTOGRAM_O4.hdf o4-config-loader:/mnt/o4-config/pta_files/H1V1-PTA_HISTOGRAM_O4.hdf
kubectl -n flare cp /Users/oliver/Developer/pycbc/examples/live/live-analysis/prod/o4/full_bandwidth/pta_files/L1V1-PTA_HISTOGRAM_O4.hdf o4-config-loader:/mnt/o4-config/pta_files/L1V1-PTA_HISTOGRAM_O4.hdf
```

For a smoke test, the MPIJob is configured to use a smaller bank file at
`/workspace/o4-config/bank/O4_TEST_SMALL_BANK.hdf`. Create it locally from the
full O4 bank:

```sh
pycbc_hdf5_splitbank \
  --bank-file /Users/oliver/Developer/pycbc/examples/live/live-analysis/prod/o4/full_bandwidth/bank/O4_DESIGN_OPT_FLOW_HYBRID_BANK_O3_CONFIG.hdf \
  --output-prefix /tmp/O4_test_bank_ \
  --random-sort \
  --random-seed 831486 \
  --templates-per-bank 10000
```

Copy one of the split files into the config PVC with the expected test-bank name:

```sh
kubectl -n flare cp /tmp/O4_test_bank_0.hdf o4-config-loader:/mnt/o4-config/bank/O4_TEST_SMALL_BANK.hdf
```

To go back to the full bank later, remove the `BANK_FILE` environment variable
from `mpi-job.yaml`.

Create the output directory on the output PVC:

```sh
kubectl -n flare exec o4-output-loader -- sh -c '
mkdir -p /mnt/o4-output/triggers
'
```

Fix ownership and permissions on the output PVC for the `mpi-user` runtime:

```sh
kubectl -n flare exec o4-output-loader -- sh -c '
chown -R 1000:1000 /mnt/o4-output &&
chmod -R ug+rwX /mnt/o4-output
'
```

Optional verification:

```sh
kubectl -n flare exec o4-config-loader -- find /mnt/o4-config -maxdepth 3 -type f | sort
```

```sh
kubectl -n flare exec o4-output-loader -- find /mnt/o4-output -maxdepth 2 | sort
```

Delete the loader pods after seeding:

```sh
kubectl -n flare delete pod o4-config-loader o4-output-loader
```

## Important Environment Variables

- `CONF_DIR`: mounted O4 configuration directory. Default: `/workspace/o4-config`.
- `LOCAL_DIR`: mounted output directory. Default: `/workspace/o4-output`.
- `FRAME_DIR`: mounted replay/static frame directory. Default: `/workspace/frames`.
- `H1_FRAME_DIR`: H1 frame directory. Manifest default: `/workspace/frames/H1_O4LLPIC`.
- `L1_FRAME_DIR`: L1 frame directory. Manifest default: `/workspace/frames/L1_O4LLPIC`.
- `V1_FRAME_DIR`: V1 frame directory. Manifest default: `/workspace/frames/V1_O4LLPIC`.
- `MPI_NP`: total MPI ranks. Default in the manifest: `3`.
- `OMP_NUM_THREADS`: CPU threads per rank. Default in the manifest: `4`.
- `ENABLE_GRACEDB_UPLOAD`: must be set to `true` to upload. Default: `false`.
- `ENABLE_PRODUCTION_GRACEDB_UPLOAD`: must also be `true` to add production upload.
- `GRACEDB_SERVER`: GraceDB endpoint used only when upload is enabled.

## Current Scope

This first implementation intentionally does not add live frame ingestion,
fit-refresh supervision, result publication, or production GraceDB upload.
Those should be added as separate Kubernetes workloads after this static/replay
runner is validated.
