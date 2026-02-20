#!/usr/bin/env bash
# =============================================================
# server_userdata.sh.tpl
# Bootstrap script for monitoring SERVER EC2 instances.
#
# Template variables (injected by Terraform templatefile()):
#   server_name  — e.g. "server1"
#   server_port  — e.g. 9001
#   project      — e.g. "osfetch"
#   environment  — e.g. "dev"
# =============================================================
set -euo pipefail
exec > >(tee /var/log/osfetch-bootstrap.log | logger -t osfetch-bootstrap) 2>&1

echo "[BOOTSTRAP] Starting osfetch server bootstrap — $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── 1. System update + Python 3.11 ──────────────────────────
dnf update -y --quiet
dnf install -y python3.11 python3.11-pip python3.11-devel gcc --quiet

# Verify Python version
python3.11 --version

# ── 2. Application directory ─────────────────────────────────
mkdir -p /opt/osfetch
cd /opt/osfetch

# ── 3. Install Python dependencies ───────────────────────────
# psutil needs C headers (python3.11-devel + gcc installed above)
pip3.11 install --quiet --no-cache-dir psutil>=7.2.0

# ── 4. Write monitor_server.py ───────────────────────────────
# The file is embedded verbatim so the EC2 is self-contained —
# no git clone, no S3, no external dependency at runtime.
cat > /opt/osfetch/monitor_server.py << 'PYEOF'
#!/usr/bin/env python3
"""
Server Monitoring Application
Collects and streams system metrics to connected clients via the middleware
"""

import asyncio
import json
import os
import platform
import socket
from datetime import datetime
from typing import Any, Dict

import psutil


class ServerMonitor:
    """Collects comprehensive system metrics"""

    def __init__(self, server_name: str = None) -> None:
        self.server_name: str = server_name or socket.gethostname()
        self.start_time: datetime = datetime.now()

    def get_cpu_info(self) -> Dict[str, Any]:
        """Get detailed CPU information."""
        cpu_freq = psutil.cpu_freq()
        return {
            "usage_percent": psutil.cpu_percent(interval=0.1, percpu=True),
            "usage_total": psutil.cpu_percent(interval=0.1),
            "count_physical": psutil.cpu_count(logical=False),
            "count_logical": psutil.cpu_count(logical=True),
            "frequency_current": cpu_freq.current if cpu_freq else 0,
            "frequency_max": cpu_freq.max if cpu_freq else 0,
            "load_avg": list(os.getloadavg()) if hasattr(os, "getloadavg") else [0, 0, 0],
        }

    def get_memory_info(self) -> Dict[str, Any]:
        """Get virtual and swap memory information."""
        virtual = psutil.virtual_memory()
        swap = psutil.swap_memory()
        return {
            "virtual": {
                "total": virtual.total,
                "available": virtual.available,
                "used": virtual.used,
                "percent": virtual.percent,
                "total_gb": round(virtual.total / (1024**3), 2),
                "used_gb": round(virtual.used / (1024**3), 2),
                "available_gb": round(virtual.available / (1024**3), 2),
            },
            "swap": {
                "total": swap.total,
                "used": swap.used,
                "free": swap.free,
                "percent": swap.percent,
                "total_gb": round(swap.total / (1024**3), 2),
                "used_gb": round(swap.used / (1024**3), 2),
            },
        }

    def get_disk_info(self) -> Dict[str, Any]:
        """Get disk partition and I/O information."""
        partitions = []
        for partition in psutil.disk_partitions():
            try:
                usage = psutil.disk_usage(partition.mountpoint)
                partitions.append({
                    "device": partition.device,
                    "mountpoint": partition.mountpoint,
                    "fstype": partition.fstype,
                    "total": usage.total,
                    "used": usage.used,
                    "free": usage.free,
                    "percent": usage.percent,
                    "total_gb": round(usage.total / (1024**3), 2),
                    "used_gb": round(usage.used / (1024**3), 2),
                    "free_gb": round(usage.free / (1024**3), 2),
                })
            except PermissionError:
                continue
        disk_io = psutil.disk_io_counters()
        return {
            "partitions": partitions,
            "io": {
                "read_bytes": disk_io.read_bytes if disk_io else 0,
                "write_bytes": disk_io.write_bytes if disk_io else 0,
                "read_count": disk_io.read_count if disk_io else 0,
                "write_count": disk_io.write_count if disk_io else 0,
                "read_gb": round(disk_io.read_bytes / (1024**3), 2) if disk_io else 0,
                "write_gb": round(disk_io.write_bytes / (1024**3), 2) if disk_io else 0,
            },
        }

    def get_network_info(self) -> Dict[str, Any]:
        """Get network I/O and interface information."""
        net_io = psutil.net_io_counters()
        connections = len(psutil.net_connections())
        interfaces: Dict[str, Any] = {}
        for interface, addrs in psutil.net_if_addrs().items():
            interfaces[interface] = [
                {
                    "family": str(addr.family),
                    "address": addr.address,
                    "netmask": addr.netmask,
                    "broadcast": addr.broadcast,
                }
                for addr in addrs
            ]
        return {
            "io": {
                "bytes_sent": net_io.bytes_sent,
                "bytes_recv": net_io.bytes_recv,
                "packets_sent": net_io.packets_sent,
                "packets_recv": net_io.packets_recv,
                "errin": net_io.errin,
                "errout": net_io.errout,
                "dropin": net_io.dropin,
                "dropout": net_io.dropout,
                "sent_gb": round(net_io.bytes_sent / (1024**3), 2),
                "recv_gb": round(net_io.bytes_recv / (1024**3), 2),
            },
            "connections": connections,
            "interfaces": interfaces,
        }

    def get_process_info(self, limit: int = 10) -> list:
        """Return top processes sorted by CPU usage."""
        processes = []
        for proc in psutil.process_iter(
            ["pid", "name", "cpu_percent", "memory_percent", "status", "username"]
        ):
            try:
                processes.append({
                    "pid": proc.info["pid"],
                    "name": proc.info["name"],
                    "cpu_percent": proc.info["cpu_percent"] or 0,
                    "memory_percent": round(proc.info["memory_percent"] or 0, 2),
                    "status": proc.info["status"],
                    "username": proc.info["username"],
                })
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue
        processes.sort(key=lambda x: x["cpu_percent"], reverse=True)
        return processes[:limit]

    def stop_process(self, pid: int) -> Dict[str, Any]:
        """Stop (terminate) a process by PID.

        Args:
            pid: Process ID to terminate.

        Returns:
            Dictionary with success status and message.
        """
        try:
            proc = psutil.Process(pid)
            proc_name = proc.name()
            proc.terminate()
            try:
                proc.wait(timeout=3)
                return {
                    "success": True,
                    "pid": pid,
                    "name": proc_name,
                    "message": f"Process {proc_name} (PID: {pid}) terminated successfully",
                }
            except psutil.TimeoutExpired:
                proc.kill()
                return {
                    "success": True,
                    "pid": pid,
                    "name": proc_name,
                    "message": f"Process {proc_name} (PID: {pid}) killed forcefully",
                }
        except psutil.NoSuchProcess:
            return {"success": False, "pid": pid, "error": f"Process with PID {pid} not found"}
        except psutil.AccessDenied:
            return {"success": False, "pid": pid, "error": f"Access denied: cannot terminate process {pid}"}
        except Exception as e:
            return {"success": False, "pid": pid, "error": f"Failed to terminate process: {str(e)}"}

    def start_process(self, command: str) -> Dict[str, Any]:
        """Start a new process by shell command string.

        Args:
            command: Shell command to execute.

        Returns:
            Dictionary with success status, PID, and message.
        """
        import shlex
        import subprocess

        args: list = []
        try:
            args = shlex.split(command)
            if not args:
                return {"success": False, "command": command, "error": "Empty command provided"}
            proc = subprocess.Popen(
                args,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
            )
            return {
                "success": True,
                "pid": proc.pid,
                "command": command,
                "message": f"Process started successfully with PID {proc.pid}",
            }
        except FileNotFoundError:
            return {
                "success": False,
                "command": command,
                "error": f"Command not found: {args[0] if args else command}",
            }
        except Exception as e:
            return {"success": False, "command": command, "error": f"Failed to start process: {str(e)}"}

    def get_system_info(self) -> Dict[str, Any]:
        """Get static system information and uptime."""
        boot_time = datetime.fromtimestamp(psutil.boot_time())
        uptime = datetime.now() - boot_time
        return {
            "hostname": self.server_name,
            "platform": platform.system(),
            "platform_release": platform.release(),
            "platform_version": platform.version(),
            "architecture": platform.machine(),
            "processor": platform.processor(),
            "boot_time": boot_time.isoformat(),
            "uptime_seconds": uptime.total_seconds(),
            "uptime_formatted": str(uptime).split(".")[0],
            "timestamp": datetime.now().isoformat(),
        }

    def get_full_metrics(self) -> Dict[str, Any]:
        """Collect and return all metrics in a single dict."""
        return {
            "server_name": self.server_name,
            "system": self.get_system_info(),
            "cpu": self.get_cpu_info(),
            "memory": self.get_memory_info(),
            "disk": self.get_disk_info(),
            "network": self.get_network_info(),
            "top_processes": self.get_process_info(),
        }


class MonitoringServer:
    """TCP async server for streaming metrics."""

    def __init__(self, host: str = "0.0.0.0", port: int = 9001, server_name: str = None) -> None:
        self.host = host
        self.port = port
        self.monitor = ServerMonitor(server_name)
        self.clients: set = set()

    async def handle_command(self, command_data: dict, writer: asyncio.StreamWriter) -> None:
        action = command_data.get("action", "").upper()
        if action == "STOP":
            pid = command_data.get("pid")
            if pid is None:
                response = {
                    "type": "command_result",
                    "action": "stop",
                    "success": False,
                    "error": "Missing PID parameter",
                }
            else:
                result = self.monitor.stop_process(int(pid))
                response = {"type": "command_result", "action": "stop", **result}
        elif action == "START":
            command = command_data.get("command")
            if not command:
                response = {
                    "type": "command_result",
                    "action": "start",
                    "success": False,
                    "error": "Missing command parameter",
                }
            else:
                result = self.monitor.start_process(command)
                response = {"type": "command_result", "action": "start", **result}
        else:
            response = {
                "type": "command_result",
                "success": False,
                "error": f"Unknown action: {action}",
            }
        try:
            writer.write(json.dumps(response).encode() + b"\n")
            await writer.drain()
        except (ConnectionResetError, BrokenPipeError):
            pass

    async def listen_for_commands(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        try:
            while True:
                try:
                    data = await reader.readline()
                    if not data:
                        break
                    try:
                        command_data = json.loads(data.decode("utf-8"))
                        if isinstance(command_data, dict) and "action" in command_data:
                            await self.handle_command(command_data, writer)
                    except json.JSONDecodeError:
                        pass
                except (ConnectionResetError, BrokenPipeError):
                    break
        except asyncio.CancelledError:
            pass
        except Exception as e:
            print(f"[ERROR] Command listener error: {e}")

    async def stream_metrics(self, writer: asyncio.StreamWriter) -> None:
        try:
            while True:
                metrics = self.monitor.get_full_metrics()
                message = {"type": "metrics", "data": metrics}
                try:
                    writer.write(json.dumps(message).encode() + b"\n")
                    await writer.drain()
                    await asyncio.sleep(2)
                except (ConnectionResetError, BrokenPipeError):
                    break
        except asyncio.CancelledError:
            pass

    async def handle_client(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        addr = writer.get_extra_info("peername")
        print(f"[INFO] Client connected: {addr}")
        self.clients.add(writer)
        try:
            welcome = {
                "type": "handshake",
                "server_name": self.monitor.server_name,
                "message": "Connected to monitoring server",
                "capabilities": ["metrics", "stop_process", "start_process"],
            }
            writer.write(json.dumps(welcome).encode() + b"\n")
            await writer.drain()

            metrics_task = asyncio.create_task(self.stream_metrics(writer))
            commands_task = asyncio.create_task(self.listen_for_commands(reader, writer))
            done, pending = await asyncio.wait(
                [metrics_task, commands_task], return_when=asyncio.FIRST_COMPLETED
            )
            for task in pending:
                task.cancel()
                try:
                    await task
                except asyncio.CancelledError:
                    pass
        except Exception as e:
            print(f"[ERROR] Client {addr} error: {e}")
        finally:
            print(f"[INFO] Client disconnected: {addr}")
            self.clients.discard(writer)
            writer.close()
            await writer.wait_closed()

    async def start(self) -> None:
        server = await asyncio.start_server(self.handle_client, self.host, self.port)
        addr = server.sockets[0].getsockname()
        print(f"[INFO] Monitoring server '{self.monitor.server_name}' started on {addr}")
        async with server:
            await server.serve_forever()


async def main() -> None:
    server_name = os.getenv("SERVER_NAME", socket.gethostname())
    port = int(os.getenv("SERVER_PORT", "9001"))
    print(f"[STARTUP] Initializing monitoring server: {server_name}")
    server = MonitoringServer(port=port, server_name=server_name)
    try:
        await server.start()
    except KeyboardInterrupt:
        print("\n[SHUTDOWN] Server shutting down...")


if __name__ == "__main__":
    asyncio.run(main())
PYEOF

echo "[BOOTSTRAP] monitor_server.py written"

# ── 5. Write systemd service unit ────────────────────────────
cat > /etc/systemd/system/osfetch-server.service << EOF
[Unit]
Description=osfetch Monitoring Server (${project}/${environment})
Documentation=https://github.com/anomalyco/osfetch
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/osfetch

# Runtime configuration — matches docker-compose environment block
Environment="SERVER_NAME=${server_name}"
Environment="SERVER_PORT=${server_port}"

ExecStart=/usr/bin/python3.11 -u /opt/osfetch/monitor_server.py

# Restart policy: restart on any failure, back off up to 30 s
Restart=on-failure
RestartSec=5s
StartLimitInterval=60s
StartLimitBurst=5

# Capture all stdout/stderr via journald
StandardOutput=journal
StandardError=journal
SyslogIdentifier=osfetch-server

[Install]
WantedBy=multi-user.target
EOF

echo "[BOOTSTRAP] systemd unit written"

# ── 6. Enable and start the service ──────────────────────────
systemctl daemon-reload
systemctl enable osfetch-server.service
systemctl start  osfetch-server.service

# ── 7. Verify it came up (allow up to 15 s) ──────────────────
for i in $(seq 1 15); do
  if systemctl is-active --quiet osfetch-server.service; then
    echo "[BOOTSTRAP] osfetch-server is running"
    break
  fi
  echo "[BOOTSTRAP] Waiting for service... ($i/15)"
  sleep 1
done

systemctl status osfetch-server.service --no-pager || true

echo "[BOOTSTRAP] Completed — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
