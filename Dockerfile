FROM python:3.11-slim-trixie

# ARG port=2222

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

RUN git clone https://github.com/olivergrabinski/pycbc \
    git checkout slim-container

RUN pip install --no-cache-dir \
    pycbc

CMD ["sleep", "infinity"]
