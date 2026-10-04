FROM ghcr.io/astral-sh/uv:0.12.21 AS uv
FROM python:3.12-slim

COPY --from=uv /uv /bin/uv

WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev
ENV PATH="/app/.venv/bin:$PATH"

COPY main.py ./

# Don't run as root inside the container.
RUN useradd --uid 10001 app
USER app

ENTRYPOINT ["python", "main.py"]
