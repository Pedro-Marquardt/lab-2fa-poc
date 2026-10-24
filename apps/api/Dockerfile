# Bioentropy lab API (FastAPI). Store is in-memory — data dies with the container.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

RUN useradd --create-home --uid 1000 --shell /bin/bash app

COPY pyproject.toml README.md requirements.txt ./
COPY bioentropy_api ./bioentropy_api

RUN pip install --upgrade pip \
    && pip install .

USER app
EXPOSE 8000

# 0.0.0.0 so desktop/phone on the LAN (or Docker host) can reach tickets.
CMD ["uvicorn", "bioentropy_api.main:app", "--host", "0.0.0.0", "--port", "8000"]
