FROM python:3.11-slim

WORKDIR /app

# Install UV
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Install dependencies using UV
COPY pyproject.toml .
RUN uv pip install --system .

# Copy application
COPY . .

EXPOSE 8501

# Run the streamlit app
CMD ["python", "-m", "streamlit", "run", "app.py", "--server.port=8501", "--server.address=0.0.0.0"]
