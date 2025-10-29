FROM python:3.11.14-trixie

ARG port=2222

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    OMP_NUM_THREADS=4 \
    HDF5_USE_FILE_LOCKING=FALSE \
    OMPI_MCA_btl_vader_single_copy_mechanism=none

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    sudo \
    openssh-server \
    openssh-client \
    libcap2-bin \
    build-essential \
    gfortran \
    pkg-config \
    git \
    libfftw3-dev \
    libgsl-dev \
    libhdf5-dev \
    libblas-dev \
    liblapack-dev \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
    "pycbc>=2.4" \
    lalsuite \
    mpi4py \
    openmpi \
    "numpy<2.2.2" \
    scipy \
    matplotlib \
    pandas \
    h5py \
    cython \
    ligo.skymap \
    igwn-ligolw

WORKDIR /workspace

RUN mkdir -p /workspace/SEOBNRv4ROM && \
    curl -L "https://git.ligo.org/waveforms/software/lalsuite-waveform-data/-/raw/18aeddc827b0a54062c93d314d2b73257cd460b2/waveform_data/SEOBNRv4ROM_v3.0.hdf5" \
    -o /workspace/SEOBNRv4ROM/SEOBNRv4ROM_v3.0.hdf5
ENV LAL_DATA_PATH=/workspace/SEOBNRv4ROM


COPY scripts .

# Add priviledge separation directoy to run sshd as root.
RUN mkdir -p /var/run/sshd
# Add capability to run sshd as non-root.
RUN setcap CAP_NET_BIND_SERVICE=+eip /usr/sbin/sshd
RUN apt remove libcap2-bin -y

# Allow OpenSSH to talk to containers without asking for confirmation
# by disabling StrictHostKeyChecking.
# mpi-operator mounts the .ssh folder from a Secret. For that to work, we need
# to disable UserKnownHostsFile to avoid write permissions.
# Disabling StrictModes avoids directory and files read permission checks.
# https://github.com/kubeflow/mpi-operator/blob/b1c5c9d0606d7870d8698980e3ffa1f0ebec0639/build/base/Dockerfile
RUN sed -i "s/[ #]\(.*StrictHostKeyChecking \).*/ \1no/g" /etc/ssh/ssh_config \
    && echo "    UserKnownHostsFile /dev/null" >> /etc/ssh/ssh_config \
    && sed -i "s/[ #]\(.*Port \).*/ \1$port/g" /etc/ssh/ssh_config \
    && sed -i "s/#\(StrictModes \).*/\1no/g" /etc/ssh/sshd_config \
    && sed -i "s/#\(Port \).*/\1$port/g" /etc/ssh/sshd_config

COPY entrypoint.sh /opt/bin/entrypoint.sh
RUN chmod +x /opt/bin/entrypoint.sh

COPY run.sh /workspace/run.sh
RUN chmod +x /workspace/run.sh

EXPOSE 22
ENTRYPOINT ["/opt/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
