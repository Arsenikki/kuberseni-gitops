# syntax=docker/dockerfile:1
FROM python:3.11-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
  curl \
  unzip \
  wget \
  gnupg \
  && rm -rf /var/lib/apt/lists/*

# Install OpenTofu using standalone method with correct syntax
RUN curl -fsSL https://get.opentofu.org/install-opentofu.sh | sh -s -- --install-method standalone

# Install talosctl
RUN curl -sL https://talos.dev/install | sh

# Install uv
RUN pip install --no-cache-dir uv

WORKDIR /app

# Copy project files
COPY . /app/

# Install dependencies using uv from pyproject.toml
RUN uv pip install . --system

ENV TEMPORAL_TARGET=temporal:7233 \
  TEMPORAL_TASK_QUEUE=talos-management \
  REPO_ROOT=/app \
  ALLOW_APPLY=false

CMD ["python", "worker.py"]
