FROM python:3.11-slim

WORKDIR /app

# Install UV
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Install dependencies using UV
COPY pyproject.toml .
RUN uv sync

# Copy application
COPY monitor_server.py .

# Run the server using UV
CMD ["uv", "run", "python", "-u", "monitor_server.py"]
