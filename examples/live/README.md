# PyCBC Live on k8s with MPIOperator

This repository holds two related workflows:

1. Generate the template banks, injections, and supporting files required by PyCBC Live.
2. Build and launch the PyCBC Live MPI workload on a Minikube cluster using the manifests in `k8s`.

Both flows assume Docker (with the Compose plugin), Minikube, and `kubectl` are already installed locally.

---

## 1. Generate Input Data

All of the scripts under `input_data_generation/` run inside a lightweight Docker container. The outputs land in `input_data_generation/tmp/` so they can later be copied into Kubernetes storage.

1. Change into the generator directory:
   ```bash
   cd input_data_generation
   ```
2. Build the helper image and populate the `tmp/` folder:
   ```bash
   docker compose build
   docker compose run --rm generate
   ```
   The container runs `generate.sh`, which:
   - Downloads and trims a template bank.
   - Creates injection, fit coefficient, and significance files.
   - Synthesises strain data and summary statistics.
3. Inspect `input_data_generation/tmp/` and keep it intact. Those files must be copied to the Kubernetes persistent volume before launching PyCBC Live.

> Tip: If you regenerate the data, clear the `tmp/` directory first to avoid mixing files from different runs.

---

## 2. Build and Run PyCBC Live on Minikube

The manifests in `k8s/` assume payloads are mounted at `/workspace/tmp`. Follow the steps below to build the image, stage the input data, and submit the MPI job.

1. Build the runtime image locally:
   ```bash
   docker build -t pycbc-live:k8s k8s
   ```
   The Dockerfile fetches the SEOBNR ROM data directly and sets `LAL_DATA_PATH` inside the image.
2. Push the image into the Minikube registry:
   ```bash
   minikube image load pycbc-live:k8s
   ```
3. Ensure the [Kubeflow MPI Operator](https://github.com/kubeflow/mpi-operator) is installed. The simplest path to apply the official `mpi-operator.yaml`.
   ```bash
   kubectl apply --server-side -f https://raw.githubusercontent.com/kubeflow/mpi-operator/v0.7.0/deploy/v2beta1/mpi-operator.yaml
   ```
4. Provision a persistent volume and a temporary pod that keeps it mounted:
   ```bash
   kubectl apply -f k8s/pv.yaml
   kubectl wait --for=condition=Ready pod/pvc-seeder
   ```
5. Copy the generated inputs into the persistent volume (run from the repo root):
   ```bash
   kubectl cp input_data_generation/tmp/. pvc-seeder:/workspace/tmp
   ```
   Leave the `pvc-seeder` pod running until after the copy completes; it can be deleted later with `kubectl delete pod pvc-seeder`.
6. Submit the PyCBC Live MPI job:
   ```bash
   kubectl apply -f k8s/mpi-job.yaml
   ```
7. Monitor the launch pod and workers, focusing on the launcher logs to verify the end-of-run checks complete successfully:
   ```bash
   kubectl get mpijobs
   kubectl get pods -l job-name=pycbc-live-launcher
   kubectl logs -f <launcher-pod-name> -c launcher
   ```
8. (Optional) When the run finishes, collect results from the persistent volume. For example:
   ```bash
   kubectl cp pvc-seeder:/workspace/tmp/output ./output
   ```

Clean up resources (optional):
```bash
kubectl delete -f k8s/mpi-job.yaml
kubectl delete pod pvc-seeder
kubectl delete -f k8s/pv.yaml
```

With these steps the MPI job should locate the ROM data and the generated inputs, and PyCBC Live will write its outputs back into the shared volume. Be sure to rebuild the image (`docker build …`) after any Dockerfile changes so Minikube receives the updates.

---

## Follow-up TODOs

- [ ] Audit the SSH setup in `k8s/entrypoint.sh` / Dockerfile (capabilities, config tweaks) and replace it with a minimal solution documented for the MPI Operator.
- [ ] Review the LAL_DATA_PATH env variable
