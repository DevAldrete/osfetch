#!/usr/bin/env bash
# =============================================================
# client_userdata.sh.tpl
# Bootstrap script for the CLIENT EC2 instance.
#
# This instance hosts the Streamlit Web UI for the osfetch monitoring system.
#
# Template variables (injected by Terraform templatefile()):
#   middleware_host — private IP of the middleware EC2
#   middleware_port — e.g. 9000
#   project         — e.g. "osfetch"
#   environment     — e.g. "dev"
#   auth_token      — shared secret for backend connections
#   ui_password     — password for the Streamlit web UI
# =============================================================
set -euo pipefail
exec > >(tee /var/log/osfetch-bootstrap.log | logger -t osfetch-bootstrap) 2>&1

echo "[BOOTSTRAP] Starting osfetch client bootstrap — $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── 1. System update ─────────────────────────────────────────
dnf update -y --quiet

# ── 2. Install Docker (official Amazon Linux 2023 package) ───
dnf install -y docker --quiet

# Enable + start Docker daemon
systemctl enable --now docker

# Allow ec2-user to run docker without sudo
usermod -aG docker ec2-user

# Verify Docker is up
docker version --format '{{.Server.Version}}'

# ── 3. Create application directory ──────────────────────────
mkdir -p /opt/osfetch/client
cd /opt/osfetch/client

# ── 4. Write application files ───────────────────────────────

cat > /opt/osfetch/client/pyproject.toml << 'PYEOF'
[project]
name = "os-monitoring-client"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = [
    "rich>=14.0.0",
    "streamlit>=1.37.0",
    "pandas>=2.0.0",
    "plotly>=5.18.0",
]

[dependency-groups]
dev = []
PYEOF
echo "[BOOTSTRAP] pyproject.toml written"

cat > /opt/osfetch/client/api.py << 'PYEOF'
import json
import socket
import os
import time

MIDDLEWARE_HOST = os.getenv("MIDDLEWARE_HOST", "localhost")
MIDDLEWARE_PORT = int(os.getenv("MIDDLEWARE_PORT", 9000))
AUTH_TOKEN = os.getenv("AUTH_TOKEN")  # if needed by UI, though middleware handles it


def get_server_list():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(5.0)
            s.connect((MIDDLEWARE_HOST, MIDDLEWARE_PORT))
            f = s.makefile("r", encoding="utf-8")
            # Wait for welcome and server_list
            f.readline()  # welcome
            server_list_str = f.readline()

            s.sendall(b"LIST\n")
            line = f.readline()
            data = json.loads(line.strip())
            if data.get("type") == "server_list":
                return data.get("servers", {})
    except Exception as e:
        print(f"Error getting server list: {e}")
    return {}


def get_server_metrics(server_name):
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(5.0)
            s.connect((MIDDLEWARE_HOST, MIDDLEWARE_PORT))
            f = s.makefile("r", encoding="utf-8")

            f.readline()
            f.readline()

            s.sendall(f"CONNECT {server_name}\n".encode())

            # proxy conf
            f.readline()

            # server handshake
            f.readline()

            # first metrics!
            line = f.readline()
            data = json.loads(line.strip())

            if data.get("type") == "metrics":
                return data.get("data", {})
    except Exception as e:
        print(f"Error getting metrics for {server_name}: {e}")
    return None


def send_command(server_name, action, **kwargs):
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(5.0)
            s.connect((MIDDLEWARE_HOST, MIDDLEWARE_PORT))
            f = s.makefile("r", encoding="utf-8")

            f.readline()
            f.readline()

            s.sendall(f"CONNECT {server_name}\n".encode())
            f.readline()  # proxy conf
            f.readline()  # server handshake

            # Send command
            cmd = {"action": action}
            cmd.update(kwargs)
            # Add auth token if provided by env
            if AUTH_TOKEN:
                cmd["auth_token"] = AUTH_TOKEN

            s.sendall(json.dumps(cmd).encode() + b"\n")

            # Read until we get command_result
            start = time.time()
            while time.time() - start < 5.0:
                line = f.readline()
                if not line:
                    break
                data = json.loads(line.strip())
                if data.get("type") == "command_result":
                    return data
    except Exception as e:
        print(f"Error sending command to {server_name}: {e}")
    return {"success": False, "error": "Connection failed"}
PYEOF
echo "[BOOTSTRAP] api.py written"

cat > /opt/osfetch/client/app.py << 'PYEOF'
import streamlit as st
import pandas as pd
import time
import os
from api import get_server_list, get_server_metrics, send_command

# Configuration
UI_PASSWORD = os.getenv("UI_PASSWORD")

st.set_page_config(page_title="OSFetch Monitoring", page_icon="🖥️", layout="wide")

# --- Authentication ---
if UI_PASSWORD:
    if "authenticated" not in st.session_state:
        st.session_state.authenticated = False

    if not st.session_state.authenticated:
        st.title("Login Required")
        pwd = st.text_input("Password", type="password")
        if st.button("Login"):
            if pwd == UI_PASSWORD:
                st.session_state.authenticated = True
                st.rerun()
            else:
                st.error("Invalid password")
        st.stop()  # Halt execution if not authenticated

# --- Main App ---
st.title("OSFetch Dashboard")

# Sidebar - Server Selection
st.sidebar.header("Servers")
servers = get_server_list()

if not servers:
    st.sidebar.warning("No servers available or middleware disconnected.")
    st.stop()

server_names = list(servers.keys())
selected_server = st.sidebar.selectbox("Select Server", server_names)

# Auto-refresh
auto_refresh = st.sidebar.checkbox("Auto-Refresh (2s)", value=True)

# Main Content
if selected_server:
    st.header(f"Monitoring: {selected_server}")

    # Process Control Actions
    st.sidebar.subheader("Actions")
    with st.sidebar.form("start_process"):
        cmd = st.text_input("Command to start")
        if st.form_submit_button("Start Process"):
            res = send_command(selected_server, "START", command=cmd)
            if res.get("success"):
                st.success(res.get("message", "Started"))
            else:
                st.error(res.get("error", "Failed"))

    with st.sidebar.form("stop_process"):
        pid_to_stop = st.number_input("PID to stop", min_value=1, step=1)
        if st.form_submit_button("Stop Process"):
            res = send_command(selected_server, "STOP", pid=pid_to_stop)
            if res.get("success"):
                st.success(res.get("message", "Stopped"))
            else:
                st.error(res.get("error", "Failed"))

    # Render Metrics
    @st.fragment(run_every="2s" if auto_refresh else None)
    def display_metrics():
        metrics = get_server_metrics(selected_server)
        if not metrics:
            st.error("Failed to fetch metrics.")
            return

        sys_info = metrics.get("system", {})
        cpu = metrics.get("cpu", {})
        mem = metrics.get("memory", {})
        disk = metrics.get("disk", {})

        # System Info Row
        st.subheader("System Info")
        col1, col2, col3, col4 = st.columns(4)
        col1.metric(
            "OS", f"{sys_info.get('platform')} {sys_info.get('platform_release')}"
        )
        col2.metric("Uptime", sys_info.get("uptime_formatted", "N/A"))
        col3.metric("CPU Cores", cpu.get("count_logical", 0))
        col4.metric("Load Avg", str(cpu.get("load_avg", [])))

        # CPU & Mem Row
        col_cpu, col_mem = st.columns(2)
        with col_cpu:
            st.subheader("CPU Usage")
            st.progress(cpu.get("usage_total", 0) / 100.0)
            st.text(f"Total: {cpu.get('usage_total', 0)}%")

        with col_mem:
            st.subheader("Memory Usage")
            vm = mem.get("virtual", {})
            st.progress(vm.get("percent", 0) / 100.0)
            st.text(
                f"{vm.get('used_gb', 0)} GB / {vm.get('total_gb', 0)} GB ({vm.get('percent', 0)}%)"
            )

        # Disks
        st.subheader("Disk Partitions")
        parts = disk.get("partitions", [])
        if parts:
            df_parts = pd.DataFrame(parts)
            st.dataframe(
                df_parts[["mountpoint", "fstype", "total_gb", "used_gb", "percent"]],
                use_container_width=True,
            )

        # Top Processes
        st.subheader("Top Processes (by CPU)")
        procs = metrics.get("top_processes", [])
        if procs:
            df_procs = pd.DataFrame(procs)
            st.dataframe(
                df_procs[
                    [
                        "pid",
                        "name",
                        "user" if "user" in df_procs.columns else "username",
                        "cpu_percent",
                        "memory_percent",
                        "status",
                    ]
                ],
                use_container_width=True,
            )

    display_metrics()
PYEOF
echo "[BOOTSTRAP] app.py written"

cat > /opt/osfetch/client/Dockerfile << 'DEOF'
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
DEOF
echo "[BOOTSTRAP] Dockerfile written"

# ── 5. Build the Docker image ─────────────────────────────────
cd /opt/osfetch/client
docker build -t osfetch-client:latest .
echo "[BOOTSTRAP] Docker image built"

# ── 6. Run the Docker container as a daemon ───────────────────
# Run the Streamlit web app, exposing port 8501
docker run -d --restart unless-stopped \
  --name osfetch-client-app \
  -p 8501:8501 \
  -e MIDDLEWARE_HOST=${middleware_host} \
  -e MIDDLEWARE_PORT=${middleware_port} \
  -e AUTH_TOKEN=${auth_token} \
  -e UI_PASSWORD=${ui_password} \
  osfetch-client:latest

echo "[BOOTSTRAP] Streamlit app started on port 8501"

# ── 7. Write MOTD so SSH operators see instructions on login ──
cat > /etc/motd << MOTDEOF

  osfetch Streamlit Client  [${project}/${environment}]
  ─────────────────────────────────────────────────────
  Middleware : ${middleware_host}:${middleware_port}

  The Streamlit web application is running as a Docker container.
  You can access it via your browser at http://<this-instance-public-ip>:8501
  
  Useful commands:
    docker ps                      - view running containers
    docker logs -f osfetch-client-app  - view Streamlit logs
    docker restart osfetch-client-app  - restart the application

MOTDEOF

echo "[BOOTSTRAP] Completed — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
