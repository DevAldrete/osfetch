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
