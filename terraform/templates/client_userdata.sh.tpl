#!/usr/bin/env bash
# =============================================================
# client_userdata.sh.tpl
# Bootstrap script for the CLIENT EC2 instance.
#
# This instance acts as an operator bastion. The monitoring
# client TUI (monitor_client.py) runs inside Docker to keep
# the host clean and to match the existing Dockerfile exactly.
#
# Template variables (injected by Terraform templatefile()):
#   middleware_host — private IP of the middleware EC2
#   middleware_port — e.g. 9000
#   project         — e.g. "osfetch"
#   environment     — e.g. "dev"
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

# Allow ec2-user to run docker without sudo (reconnect required)
usermod -aG docker ec2-user

# Verify Docker is up
docker version --format '{{.Server.Version}}'

# ── 3. Create application directory ──────────────────────────
mkdir -p /opt/osfetch/client
cd /opt/osfetch/client

# ── 4. Write the client source file ──────────────────────────
# Copied verbatim from client/monitor_client.py in the repository.
# Embedded here to keep the bootstrap self-contained.
#
# NOTE: The heredoc uses 'PYEOF' (quoted) so the shell does NOT
#       expand $variables inside the Python source.
cat > /opt/osfetch/client/monitor_client.py << 'PYEOF'
#!/usr/bin/env python3
"""
Monitor Client Application
Rich-based full-screen terminal UI for the osfetch monitoring system.
Connects to the middleware proxy and displays real-time metrics.
"""

import asyncio
import json
import os
import select
import socket
import sys
import termios
import traceback
import tty
from datetime import datetime
from enum import Enum
from typing import Optional

from rich import box
from rich.console import Console
from rich.layout import Layout
from rich.live import Live
from rich.panel import Panel
from rich.table import Table
from rich.text import Text


# ── Exception hierarchy ──────────────────────────────────────
class MonitorErrorCode(Enum):
    CONNECTION_REFUSED = 100
    CONNECTION_TIMEOUT = 101
    CONNECTION_LOST = 102
    HOST_NOT_FOUND = 103
    INVALID_RESPONSE = 200
    UNEXPECTED_MESSAGE = 201
    JSON_DECODE_ERROR = 202
    SERVER_UNAVAILABLE = 300
    SERVER_NOT_FOUND = 301
    SERVER_ERROR = 302
    OPERATION_FAILED = 400
    INVALID_INPUT = 401
    PERMISSION_DENIED = 402
    UNKNOWN_ERROR = 500


class MonitorClientError(Exception):
    def __init__(
        self,
        message: str,
        error_code: MonitorErrorCode = MonitorErrorCode.UNKNOWN_ERROR,
        details: str = "",
        suggestion: str = "",
        original_exception: Optional[Exception] = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.error_code = error_code
        self.details = details
        self.suggestion = suggestion
        self.original_exception = original_exception
        self.timestamp = datetime.now()

    def to_dict(self) -> dict:
        return {
            "error_code": self.error_code.value,
            "error_name": self.error_code.name,
            "message": self.message,
            "details": self.details,
            "suggestion": self.suggestion,
            "timestamp": self.timestamp.isoformat(),
        }

    def create_rich_panel(self) -> Panel:
        content = Text()
        content.append(f"Error Code: {self.error_code.value} ({self.error_code.name})\n", style="bold red")
        content.append(f"Message: {self.message}\n", style="red")
        if self.details:
            content.append(f"Details: {self.details}\n", style="yellow")
        if self.suggestion:
            content.append(f"Suggestion: {self.suggestion}\n", style="green")
        content.append(f"Time: {self.timestamp.strftime('%H:%M:%S')}", style="dim")
        return Panel(content, title="[bold red]Error[/bold red]", border_style="red")


class ConnectionError(MonitorClientError):
    pass


class ProtocolError(MonitorClientError):
    pass


class ServerError(MonitorClientError):
    pass


class ClientOperationError(MonitorClientError):
    pass


# ── Main client class ─────────────────────────────────────────
class MonitoringClient:
    def __init__(self, middleware_host: str = "localhost", middleware_port: int = 9000) -> None:
        self.middleware_host = middleware_host
        self.middleware_port = middleware_port
        self.console = Console()
        self.current_metrics: Optional[dict] = None
        self.server_name: Optional[str] = None
        self.connected: bool = False
        self.reader: Optional[asyncio.StreamReader] = None
        self.writer: Optional[asyncio.StreamWriter] = None
        self._old_settings = None
        self._notification: str = ""
        self._notification_is_error: bool = False
        self._notification_time: Optional[datetime] = None

    async def connect(self) -> None:
        try:
            self.reader, self.writer = await asyncio.wait_for(
                asyncio.open_connection(self.middleware_host, self.middleware_port),
                timeout=10,
            )
            self.connected = True
        except asyncio.TimeoutError:
            raise ConnectionError(
                message=f"Connection to {self.middleware_host}:{self.middleware_port} timed out",
                error_code=MonitorErrorCode.CONNECTION_TIMEOUT,
                suggestion="Check that the middleware is running and the host/port are correct",
            )
        except (ConnectionRefusedError, OSError) as e:
            code = MonitorErrorCode.CONNECTION_REFUSED
            if isinstance(e, socket.gaierror):
                code = MonitorErrorCode.HOST_NOT_FOUND
            raise ConnectionError(
                message=f"Cannot connect to middleware at {self.middleware_host}:{self.middleware_port}",
                error_code=code,
                details=str(e),
                suggestion="Verify MIDDLEWARE_HOST and MIDDLEWARE_PORT are set correctly",
                original_exception=e,
            )

    async def receive_message(self) -> dict:
        if not self.reader:
            raise ConnectionError(
                message="Not connected",
                error_code=MonitorErrorCode.CONNECTION_LOST,
            )
        try:
            line = await asyncio.wait_for(self.reader.readline(), timeout=30)
            if not line:
                raise ConnectionError(
                    message="Connection closed by server",
                    error_code=MonitorErrorCode.CONNECTION_LOST,
                )
            return json.loads(line.decode().strip())
        except asyncio.TimeoutError:
            raise ConnectionError(
                message="Receive timed out",
                error_code=MonitorErrorCode.CONNECTION_TIMEOUT,
                suggestion="The server may be overloaded or the network is slow",
            )
        except json.JSONDecodeError as e:
            raise ProtocolError(
                message="Invalid JSON received from server",
                error_code=MonitorErrorCode.JSON_DECODE_ERROR,
                details=str(e),
                original_exception=e,
            )

    async def send_command(self, command: str) -> None:
        if not self.writer:
            raise ConnectionError(
                message="Not connected",
                error_code=MonitorErrorCode.CONNECTION_LOST,
            )
        try:
            self.writer.write(f"{command}\n".encode())
            await asyncio.wait_for(self.writer.drain(), timeout=10)
        except Exception as e:
            raise ConnectionError(
                message="Failed to send command",
                error_code=MonitorErrorCode.CONNECTION_LOST,
                details=str(e),
                original_exception=e,
            )

    async def send_json_command(self, command_data: dict) -> None:
        if not self.writer:
            raise ConnectionError(
                message="Not connected",
                error_code=MonitorErrorCode.CONNECTION_LOST,
            )
        try:
            self.writer.write(json.dumps(command_data).encode() + b"\n")
            await asyncio.wait_for(self.writer.drain(), timeout=10)
        except Exception as e:
            raise ConnectionError(
                message="Failed to send JSON command",
                error_code=MonitorErrorCode.CONNECTION_LOST,
                details=str(e),
                original_exception=e,
            )

    async def stop_process(self, pid: int) -> None:
        await self.send_json_command({"action": "stop", "pid": pid})

    async def start_process(self, command: str) -> None:
        await self.send_json_command({"action": "start", "command": command})

    async def select_server(self) -> str:
        # Read welcome
        welcome = await self.receive_message()
        if welcome.get("type") != "welcome":
            raise ProtocolError(
                message="Unexpected first message from middleware",
                error_code=MonitorErrorCode.UNEXPECTED_MESSAGE,
                details=str(welcome),
            )

        # Read server list
        server_list_msg = await self.receive_message()
        if server_list_msg.get("type") != "server_list":
            raise ProtocolError(
                message="Expected server_list message",
                error_code=MonitorErrorCode.UNEXPECTED_MESSAGE,
            )

        servers = server_list_msg.get("servers", {})
        if not servers:
            raise ServerError(
                message="No monitoring servers are registered in the middleware",
                error_code=MonitorErrorCode.SERVER_NOT_FOUND,
                suggestion="Ensure server EC2 instances are running and middleware SERVER_LIST is set",
            )

        server_names = list(servers.keys())
        if len(server_names) == 1:
            return server_names[0]

        self.console.print("\n[bold cyan]Available servers:[/bold cyan]")
        for i, name in enumerate(server_names, 1):
            info = servers[name]
            self.console.print(f"  [{i}] {name}  ({info.get('host', '?')}:{info.get('port', '?')})")

        while True:
            choice = self.console.input("\n[bold]Select server (number): [/bold]").strip()
            if choice.isdigit() and 1 <= int(choice) <= len(server_names):
                return server_names[int(choice) - 1]
            self.console.print("[red]Invalid choice.[/red]")

    def _create_usage_bar(self, percentage: float, width: int = 20) -> Text:
        filled = int(width * percentage / 100)
        empty = width - filled
        bar = Text()
        color = "green" if percentage < 60 else ("yellow" if percentage < 85 else "red")
        bar.append("█" * filled, style=color)
        bar.append("░" * empty, style="dim")
        bar.append(f" {percentage:5.1f}%")
        return bar

    def create_system_panel(self, metrics: dict) -> Panel:
        system = metrics.get("system", {})
        table = Table(box=None, show_header=False, padding=(0, 1))
        table.add_column(style="bold cyan", width=18)
        table.add_column()
        table.add_row("Hostname", system.get("hostname", "N/A"))
        table.add_row("Platform", f"{system.get('platform', '')} {system.get('platform_release', '')}")
        table.add_row("Architecture", system.get("architecture", "N/A"))
        table.add_row("Uptime", system.get("uptime_formatted", "N/A"))
        table.add_row("Boot Time", system.get("boot_time", "N/A")[:19])
        return Panel(table, title="[bold]System Info[/bold]", border_style="blue")

    def create_cpu_panel(self, metrics: dict) -> Panel:
        cpu = metrics.get("cpu", {})
        table = Table(box=None, show_header=False, padding=(0, 1))
        table.add_column(style="bold cyan", width=18)
        table.add_column()
        table.add_row("Total Usage", self._create_usage_bar(cpu.get("usage_total", 0)))
        table.add_row("Physical Cores", str(cpu.get("count_physical", "N/A")))
        table.add_row("Logical Cores", str(cpu.get("count_logical", "N/A")))
        freq = cpu.get("frequency_current", 0)
        table.add_row("Frequency", f"{freq:.0f} MHz" if freq else "N/A")
        load = cpu.get("load_avg", [0, 0, 0])
        table.add_row("Load Avg", f"{load[0]:.2f}  {load[1]:.2f}  {load[2]:.2f}")
        per_cpu = cpu.get("usage_percent", [])
        for i, pct in enumerate(per_cpu[:8]):
            table.add_row(f"  Core {i}", self._create_usage_bar(pct, width=15))
        return Panel(table, title="[bold]CPU[/bold]", border_style="green")

    def create_memory_panel(self, metrics: dict) -> Panel:
        mem = metrics.get("memory", {})
        virt = mem.get("virtual", {})
        swap = mem.get("swap", {})
        table = Table(box=None, show_header=False, padding=(0, 1))
        table.add_column(style="bold cyan", width=18)
        table.add_column()
        table.add_row("RAM Usage", self._create_usage_bar(virt.get("percent", 0)))
        table.add_row("RAM Total", f"{virt.get('total_gb', 0):.2f} GB")
        table.add_row("RAM Used", f"{virt.get('used_gb', 0):.2f} GB")
        table.add_row("RAM Available", f"{virt.get('available_gb', 0):.2f} GB")
        table.add_row("Swap Usage", self._create_usage_bar(swap.get("percent", 0)))
        table.add_row("Swap Total", f"{swap.get('total_gb', 0):.2f} GB")
        table.add_row("Swap Used", f"{swap.get('used_gb', 0):.2f} GB")
        return Panel(table, title="[bold]Memory[/bold]", border_style="yellow")

    def create_disk_panel(self, metrics: dict) -> Panel:
        disk = metrics.get("disk", {})
        table = Table(box=None, show_header=True, padding=(0, 1))
        table.add_column("Mount", style="bold cyan")
        table.add_column("Usage")
        table.add_column("Used/Total", justify="right")
        for part in disk.get("partitions", [])[:5]:
            table.add_row(
                part.get("mountpoint", "?"),
                self._create_usage_bar(part.get("percent", 0), width=12),
                f"{part.get('used_gb', 0):.1f}/{part.get('total_gb', 0):.1f} GB",
            )
        io = disk.get("io", {})
        io_text = Text(
            f"Read: {io.get('read_gb', 0):.2f} GB  Write: {io.get('write_gb', 0):.2f} GB",
            style="dim",
        )
        return Panel(
            Table.grid(padding=1).add_row(table, io_text),
            title="[bold]Disk[/bold]",
            border_style="magenta",
        )

    def create_network_panel(self, metrics: dict) -> Panel:
        net = metrics.get("network", {})
        io = net.get("io", {})
        table = Table(box=None, show_header=False, padding=(0, 1))
        table.add_column(style="bold cyan", width=18)
        table.add_column()
        table.add_row("Bytes Sent", f"{io.get('sent_gb', 0):.3f} GB")
        table.add_row("Bytes Recv", f"{io.get('recv_gb', 0):.3f} GB")
        table.add_row("Packets Sent", str(io.get("packets_sent", 0)))
        table.add_row("Packets Recv", str(io.get("packets_recv", 0)))
        table.add_row("Connections", str(net.get("connections", 0)))
        table.add_row("Errors In/Out", f"{io.get('errin', 0)} / {io.get('errout', 0)}")
        return Panel(table, title="[bold]Network[/bold]", border_style="cyan")

    def create_process_panel(self, metrics: dict, interactive: bool = False) -> Panel:
        processes = metrics.get("top_processes", [])
        table = Table(box=box.SIMPLE, show_header=True, padding=(0, 1))
        table.add_column("PID", style="bold", width=8)
        table.add_column("Name", width=20)
        table.add_column("CPU%", justify="right", width=8)
        table.add_column("MEM%", justify="right", width=8)
        table.add_column("Status", width=10)
        table.add_column("User", width=12)
        for proc in processes:
            cpu = proc.get("cpu_percent", 0)
            cpu_style = "red" if cpu > 50 else ("yellow" if cpu > 20 else "green")
            table.add_row(
                str(proc.get("pid", "")),
                proc.get("name", "")[:20],
                Text(f"{cpu:.1f}", style=cpu_style),
                f"{proc.get('memory_percent', 0):.1f}",
                proc.get("status", ""),
                (proc.get("username") or "")[:12],
            )
        hint = " [dim](s=stop  r=run)[/dim]" if interactive else ""
        return Panel(table, title=f"[bold]Top Processes{hint}[/bold]", border_style="red")

    def create_help_panel(self, interactive: bool) -> Panel:
        if interactive:
            text = Text("m=menu  s=stop process  r=run command  q=quit  (auto-refresh 2s)", style="dim")
        else:
            text = Text("View-only mode — run with --interactive/-i for process control  q=quit", style="dim")
        return Panel(text, border_style="dim")

    def create_notification_panel(self, notification: str, is_error: bool) -> Optional[Panel]:
        if not notification:
            return None
        style = "red" if is_error else "green"
        return Panel(Text(notification, style=style), border_style=style, height=3)

    def create_dashboard(
        self,
        metrics: dict,
        notification: str = "",
        is_error: bool = False,
        interactive: bool = False,
    ) -> Layout:
        layout = Layout()
        layout.split_column(
            Layout(name="header", size=1),
            Layout(name="body"),
            Layout(name="footer", size=3),
        )

        ts = metrics.get("system", {}).get("timestamp", "")[:19]
        header_text = Text(
            f" osfetch — {self.server_name or 'unknown'}  [{ts}]",
            style="bold white on blue",
        )
        layout["header"].update(header_text)

        layout["body"].split_row(
            Layout(name="left"),
            Layout(name="right"),
        )
        layout["left"].split_column(
            Layout(self.create_system_panel(metrics)),
            Layout(self.create_cpu_panel(metrics)),
            Layout(self.create_memory_panel(metrics)),
        )
        layout["right"].split_column(
            Layout(self.create_disk_panel(metrics)),
            Layout(self.create_network_panel(metrics)),
            Layout(self.create_process_panel(metrics, interactive)),
        )

        notif = self.create_notification_panel(notification, is_error)
        layout["footer"].update(notif if notif else self.create_help_panel(interactive))

        return layout

    def _setup_terminal(self) -> None:
        try:
            self._old_settings = termios.tcgetattr(sys.stdin)
            tty.setcbreak(sys.stdin.fileno())
        except Exception:
            self._old_settings = None

    def _restore_terminal(self) -> None:
        if self._old_settings:
            try:
                termios.tcsetattr(sys.stdin, termios.TCSADRAIN, self._old_settings)
            except Exception:
                pass

    def _check_keypress(self) -> Optional[str]:
        try:
            rlist, _, _ = select.select([sys.stdin], [], [], 0)
            if rlist:
                return sys.stdin.read(1)
        except Exception:
            pass
        return None

    async def prompt_stop_process(self) -> None:
        self._restore_terminal()
        try:
            pid_str = self.console.input("\n[bold]Enter PID to stop: [/bold]").strip()
            if pid_str.isdigit():
                await self.stop_process(int(pid_str))
                self._notification = f"Sent STOP to PID {pid_str}"
                self._notification_is_error = False
            else:
                self._notification = "Invalid PID"
                self._notification_is_error = True
        finally:
            self._setup_terminal()
        self._notification_time = datetime.now()

    async def prompt_start_process(self) -> None:
        self._restore_terminal()
        try:
            cmd = self.console.input("\n[bold]Command to run: [/bold]").strip()
            if cmd:
                await self.start_process(cmd)
                self._notification = f"Sent START: {cmd}"
                self._notification_is_error = False
            else:
                self._notification = "Empty command"
                self._notification_is_error = True
        finally:
            self._setup_terminal()
        self._notification_time = datetime.now()

    async def _show_command_menu(self) -> Optional[str]:
        self._restore_terminal()
        try:
            self.console.print("\n[bold cyan]Command Menu[/bold cyan]")
            self.console.print("  [1] Stop process by PID")
            self.console.print("  [2] Start process by command")
            self.console.print("  [3] Return to dashboard")
            self.console.print("  [4] Quit")
            choice = self.console.input("[bold]Choice: [/bold]").strip()
            return choice
        finally:
            self._setup_terminal()

    def _cleanup_connection(self) -> None:
        if self.writer:
            try:
                self.writer.close()
            except Exception:
                pass
        self.reader = None
        self.writer = None
        self.connected = False

    async def monitor(self) -> None:
        """View-only monitoring loop."""
        try:
            self.console.print(f"[cyan]Connecting to {self.middleware_host}:{self.middleware_port}...[/cyan]")
            await self.connect()
            server_name = await self.select_server()
            self.server_name = server_name
            await self.send_command(f"CONNECT {server_name}")

            connected_msg = await self.receive_message()
            if connected_msg.get("type") != "connected":
                raise ProtocolError(
                    message="Unexpected response to CONNECT command",
                    error_code=MonitorErrorCode.UNEXPECTED_MESSAGE,
                    details=str(connected_msg),
                )

            # Skip handshake from server
            await self.receive_message()

            with Live(console=self.console, refresh_per_second=1, screen=True) as live:
                while True:
                    try:
                        msg = await asyncio.wait_for(self.receive_message(), timeout=0.5)
                        if msg.get("type") == "metrics":
                            self.current_metrics = msg["data"]
                    except asyncio.TimeoutError:
                        pass

                    if self.current_metrics:
                        live.update(self.create_dashboard(self.current_metrics))

        except MonitorClientError as e:
            self.console.print(e.create_rich_panel())
        except KeyboardInterrupt:
            pass
        finally:
            self._cleanup_connection()

    async def _run_interactive_loop(self, live: Live) -> None:
        while True:
            # Clear old notification after 5 s
            if self._notification_time and (datetime.now() - self._notification_time).seconds > 5:
                self._notification = ""
                self._notification_time = None

            try:
                msg = await asyncio.wait_for(self.receive_message(), timeout=0.1)
                if msg.get("type") == "metrics":
                    self.current_metrics = msg["data"]
                elif msg.get("type") == "command_result":
                    success = msg.get("success", False)
                    self._notification = msg.get("message") or msg.get("error") or str(msg)
                    self._notification_is_error = not success
                    self._notification_time = datetime.now()
            except asyncio.TimeoutError:
                pass

            if self.current_metrics:
                live.update(
                    self.create_dashboard(
                        self.current_metrics,
                        self._notification,
                        self._notification_is_error,
                        interactive=True,
                    )
                )

            key = self._check_keypress()
            if key:
                if key in ("q", "Q"):
                    break
                elif key in ("s", "S"):
                    await self.prompt_stop_process()
                elif key in ("r", "R"):
                    await self.prompt_start_process()
                elif key in ("m", "M"):
                    choice = await self._show_command_menu()
                    if choice == "1":
                        await self.prompt_stop_process()
                    elif choice == "2":
                        await self.prompt_start_process()
                    elif choice == "4":
                        break

    async def interactive_monitor(self) -> None:
        """Interactive monitoring loop with process control."""
        try:
            self.console.print(f"[cyan]Connecting to {self.middleware_host}:{self.middleware_port}...[/cyan]")
            await self.connect()
            server_name = await self.select_server()
            self.server_name = server_name
            await self.send_command(f"CONNECT {server_name}")

            connected_msg = await self.receive_message()
            if connected_msg.get("type") != "connected":
                raise ProtocolError(
                    message="Unexpected response to CONNECT command",
                    error_code=MonitorErrorCode.UNEXPECTED_MESSAGE,
                    details=str(connected_msg),
                )

            await self.receive_message()  # server handshake

            self._setup_terminal()
            try:
                with Live(console=self.console, refresh_per_second=2, screen=True) as live:
                    await self._run_interactive_loop(live)
            finally:
                self._restore_terminal()

        except MonitorClientError as e:
            self.console.print(e.create_rich_panel())
        except KeyboardInterrupt:
            pass
        finally:
            self._cleanup_connection()


async def main() -> None:
    middleware_host = os.getenv("MIDDLEWARE_HOST", "localhost")
    middleware_port = int(os.getenv("MIDDLEWARE_PORT", "9000"))
    client = MonitoringClient(middleware_host, middleware_port)
    if "--interactive" in sys.argv or "-i" in sys.argv:
        await client.interactive_monitor()
    else:
        await client.monitor()


if __name__ == "__main__":
    asyncio.run(main())
PYEOF

echo "[BOOTSTRAP] monitor_client.py written"

# ── 5. Write Dockerfile ───────────────────────────────────────
cat > /opt/osfetch/client/Dockerfile << 'DEOF'
FROM python:3.11-slim

WORKDIR /app

# Install rich (the only third-party dep for the client)
RUN pip install --no-cache-dir "rich>=14.0.0"

COPY monitor_client.py .

# Default: view-only. Pass --interactive or -i for process control.
ENTRYPOINT ["python", "-u", "monitor_client.py"]
DEOF

echo "[BOOTSTRAP] Dockerfile written"

# ── 6. Build the Docker image ─────────────────────────────────
cd /opt/osfetch/client
docker build -t osfetch-client:latest .

echo "[BOOTSTRAP] Docker image built"

# ── 7. Write helper scripts ───────────────────────────────────
# Operator uses these from the SSH session instead of remembering docker run flags.

cat > /usr/local/bin/osfetch-view << SHEOF
#!/usr/bin/env bash
# View-only monitoring dashboard
exec docker run --rm -it \\
  -e MIDDLEWARE_HOST=${middleware_host} \\
  -e MIDDLEWARE_PORT=${middleware_port} \\
  osfetch-client:latest
SHEOF

cat > /usr/local/bin/osfetch-interactive << SHEOF
#!/usr/bin/env bash
# Interactive monitoring dashboard (process start/stop)
exec docker run --rm -it \\
  -e MIDDLEWARE_HOST=${middleware_host} \\
  -e MIDDLEWARE_PORT=${middleware_port} \\
  osfetch-client:latest --interactive
SHEOF

chmod +x /usr/local/bin/osfetch-view /usr/local/bin/osfetch-interactive

echo "[BOOTSTRAP] Helper scripts written to /usr/local/bin/"

# ── 8. Write MOTD so SSH operators see instructions on login ──
cat > /etc/motd << MOTDEOF

  osfetch monitoring client  [${project}/${environment}]
  ─────────────────────────────────────────────────────
  Middleware : ${middleware_host}:${middleware_port}

  Commands:
    osfetch-view          — view-only dashboard
    osfetch-interactive   — dashboard with process control

  Or run directly:
    docker run --rm -it \\
      -e MIDDLEWARE_HOST=${middleware_host} \\
      -e MIDDLEWARE_PORT=${middleware_port} \\
      osfetch-client:latest [--interactive]

MOTDEOF

echo "[BOOTSTRAP] Completed — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
