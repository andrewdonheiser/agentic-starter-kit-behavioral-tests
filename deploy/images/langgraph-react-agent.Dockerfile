# Wrapper Dockerfile that adds mlflow tracing to the upstream agent image.
# The upstream repo has tracing code but doesn't include mlflow in its dependencies.
# This avoids modifying the upstream repo while enabling trace enrichment for evals.
FROM python:3.12-slim

WORKDIR /app

RUN groupadd -r appuser && useradd -r -u 1001 -g appuser appuser

COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Copy upstream agent source
COPY pyproject.toml .
COPY src/ ./src/

# Install upstream deps + mlflow for tracing
RUN uv pip install --system --no-cache . mlflow>=3.0

COPY main.py .
COPY playground/ ./playground/

RUN chown -R appuser:appuser /app

USER appuser

EXPOSE 8080

ENV PORT=8080
ENV PYTHONPATH=/app:/app/src

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
