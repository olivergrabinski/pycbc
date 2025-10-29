FROM python:3.11.14-trixie

RUN pip install --no-cache-dir "pycbc>=2.4"

WORKDIR /workspace
COPY generate.sh .
COPY scripts .
