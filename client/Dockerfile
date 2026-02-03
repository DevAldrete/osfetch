FROM python:3.11-slim

WORKDIR /app

# Install UV
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Install dependencies using UV
COPY pyproject.toml .
RUN uv pip install --system .

# Copy application
COPY monitor_client.py .

# Run the client in interactive mode
CMD ["python", "-u", "monitor_client.py"]
