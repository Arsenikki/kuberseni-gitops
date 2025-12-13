# syntax=docker/dockerfile:1
FROM python:3.11-slim

# Install uv
RUN pip install --no-cache-dir uv

WORKDIR /app

# Copy project files
COPY temporal-python /app/temporal-python
COPY temporal-python/pyproject.toml /app/pyproject.toml
COPY temporal-python/README.md /app/README.md

# Install dependencies using uv from pyproject
RUN uv pip install . --system

ENV TEMPORAL_TARGET=temporal:7233 \
  TEMPORAL_TASK_QUEUE=talos-management \
  REPO_ROOT=/app \
  ALLOW_APPLY=false

CMD ["python", "temporal-python/worker.py"]
