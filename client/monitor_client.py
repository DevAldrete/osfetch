"""
Monitoring Client
Rich terminal UI for viewing server metrics
"""

import asyncio
import json
import os
import socket
import sys
import termios
import tty
import traceback
from datetime import datetime
from enum import Enum
from typing import Optional

from rich.console import Console
from rich.layout import Layout
from rich.panel import Panel
from rich.table import Table
from rich.live import Live
from rich.text import Text
from rich import box


class MonitorErrorCode(Enum):
    """Error codes for monitor client operations"""

    # Connection errors (1xx)
    CONNECTION_FAILED = 100
    CONNECTION_REFUSED = 101
    CONNECTION_TIMEOUT = 102
    CONNECTION_CLOSED = 103
    HOST_NOT_FOUND = 104
    NETWORK_UNREACHABLE = 105

    # Protocol errors (2xx)
    INVALID_MESSAGE = 200
    MESSAGE_DECODE_ERROR = 201
    MESSAGE_ENCODE_ERROR = 202
    UNEXPECTED_RESPONSE = 203
    PROTOCOL_VIOLATION = 204

    # Server errors (3xx)
    SERVER_NOT_FOUND = 300
    SERVER_UNAVAILABLE = 301
    SERVER_CONNECTION_FAILED = 302
    NO_SERVERS_AVAILABLE = 303

    # Client errors (4xx)
    INVALID_INPUT = 400
    OPERATION_CANCELLED = 401
    WRITE_ERROR = 402
    READ_ERROR = 403

    # Unknown errors (5xx)
    UNKNOWN_ERROR = 500


class MonitorClientError(Exception):
    """Base exception for monitor client errors with rich formatting support"""

    def __init__(
        self,
        message: str,
        error_code: MonitorErrorCode = MonitorErrorCode.UNKNOWN_ERROR,
        details: Optional[str] = None,
        suggestion: Optional[str] = None,
        original_exception: Optional[Exception] = None,
    ):
        super().__init__(message)
        self.message = message
        self.error_code = error_code
        self.details = details
        self.suggestion = suggestion
        self.original_exception = original_exception
        self.timestamp = datetime.now()

    def to_dict(self) -> dict:
        """Convert error to dictionary for logging/serialization"""
        return {
            "error_code": self.error_code.value,
            "error_name": self.error_code.name,
            "message": self.message,
            "details": self.details,
            "suggestion": self.suggestion,
            "timestamp": self.timestamp.isoformat(),
            "original_error": (
                str(self.original_exception) if self.original_exception else None
            ),
        }

    def create_rich_panel(self) -> Panel:
        """Create a rich panel for displaying the error"""
        error_text = Text()

        # Error code and name
        error_text.append(f"[{self.error_code.value}] ", style="bold red")
        error_text.append(f"{self.error_code.name}\n\n", style="bold yellow")

        # Main message
        error_text.append("Message: ", style="bold")
        error_text.append(f"{self.message}\n", style="white")

        # Details if available
        if self.details:
            error_text.append("\nDetails: ", style="bold")
            error_text.append(f"{self.details}\n", style="dim white")

        # Original exception if available
        if self.original_exception:
            error_text.append("\nOriginal Error: ", style="bold")
            error_text.append(
                f"{type(self.original_exception).__name__}: {self.original_exception}\n",
                style="dim red",
            )

        # Suggestion if available
        if self.suggestion:
            error_text.append("\nSuggestion: ", style="bold green")
            error_text.append(f"{self.suggestion}\n", style="green")

        # Timestamp
        error_text.append(
            f"\nTimestamp: {self.timestamp.strftime('%Y-%m-%d %H:%M:%S')}", style="dim"
        )

        return Panel(
            error_text,
            title="[bold red]Error[/bold red]",
            border_style="red",
            box=box.HEAVY,
            padding=(1, 2),
        )


class ConnectionError(MonitorClientError):
    """Connection-related errors"""

    pass


class ProtocolError(MonitorClientError):
    """Protocol and message format errors"""

    pass


class ServerError(MonitorClientError):
    """Server-related errors"""

    pass


class ClientOperationError(MonitorClientError):
    """Client operation errors"""

    pass


class MonitoringClient:
    """Client for connecting to middleware and displaying metrics"""

    def __init__(self, middleware_host: str = "localhost", middleware_port: int = 9000):
        self.middleware_host = middleware_host
        self.middleware_port = middleware_port
        self.console = Console()
        self.current_metrics: Optional[dict] = None
        self.server_name: Optional[str] = None
        self.connected = False
        self.reader: Optional[asyncio.StreamReader] = None
        self.writer: Optional[asyncio.StreamWriter] = None
        self._old_terminal_settings = None
        self._menu_requested = False

    def display_error(self, error: MonitorClientError) -> None:
        """Display a rich error panel to the console"""
        self.console.print()
        self.console.print(error.create_rich_panel())
        self.console.print()

    async def connect(self) -> bool:
        """Connect to middleware

        Returns:
            bool: True if connection successful, False otherwise

        Raises:
            ConnectionError: When connection fails with detailed error information
        """
        try:
            self.reader, self.writer = await asyncio.wait_for(
                asyncio.open_connection(self.middleware_host, self.middleware_port),
                timeout=10.0,
            )
            self.connected = True
            return True

        except asyncio.TimeoutError as e:
            error = ConnectionError(
                message=f"Connection to middleware timed out",
                error_code=MonitorErrorCode.CONNECTION_TIMEOUT,
                details=f"Host: {self.middleware_host}:{self.middleware_port}",
                suggestion="Check if the middleware server is running and accessible. Verify the host and port are correct.",
                original_exception=e,
            )
            self.display_error(error)
            return False

        except ConnectionRefusedError as e:
            error = ConnectionError(
                message=f"Connection refused by middleware",
                error_code=MonitorErrorCode.CONNECTION_REFUSED,
                details=f"The server at {self.middleware_host}:{self.middleware_port} actively refused the connection",
                suggestion="Ensure the middleware server is running. Check if the port is correct and not blocked by a firewall.",
                original_exception=e,
            )
            self.display_error(error)
            return False

        except socket.gaierror as e:
            error = ConnectionError(
                message=f"Host not found: {self.middleware_host}",
                error_code=MonitorErrorCode.HOST_NOT_FOUND,
                details=f"DNS resolution failed for hostname '{self.middleware_host}'",
                suggestion="Verify the hostname is correct. Check your network connection and DNS settings.",
                original_exception=e,
            )
            self.display_error(error)
            return False

        except OSError as e:
            if e.errno == 101:  # Network unreachable
                error = ConnectionError(
                    message="Network is unreachable",
                    error_code=MonitorErrorCode.NETWORK_UNREACHABLE,
                    details=f"Cannot reach {self.middleware_host}:{self.middleware_port}",
                    suggestion="Check your network connection. Verify the server is on an accessible network.",
                    original_exception=e,
                )
            else:
                error = ConnectionError(
                    message=f"OS error during connection: {e.strerror}",
                    error_code=MonitorErrorCode.CONNECTION_FAILED,
                    details=f"Error code: {e.errno}",
                    suggestion="Check system logs for more details. Verify network configuration.",
                    original_exception=e,
                )
            self.display_error(error)
            return False

        except Exception as e:
            error = ConnectionError(
                message=f"Unexpected error connecting to middleware",
                error_code=MonitorErrorCode.CONNECTION_FAILED,
                details=f"Host: {self.middleware_host}:{self.middleware_port}\n{traceback.format_exc()}",
                suggestion="Check middleware server status and network connectivity.",
                original_exception=e,
            )
            self.display_error(error)
            return False

    async def receive_message(self) -> Optional[dict]:
        """Receive a JSON message from the connection

        Returns:
            dict: Parsed JSON message or None if connection closed

        Raises:
            ProtocolError: When message cannot be received or parsed
        """
        if not self.reader:
            raise ProtocolError(
                message="Cannot receive message: not connected",
                error_code=MonitorErrorCode.CONNECTION_CLOSED,
                suggestion="Establish a connection before attempting to receive messages.",
            )

        try:
            data = await asyncio.wait_for(self.reader.readline(), timeout=30.0)

            if not data:
                return None

            try:
                return json.loads(data.decode("utf-8"))
            except json.JSONDecodeError as e:
                raise ProtocolError(
                    message="Failed to decode JSON message",
                    error_code=MonitorErrorCode.MESSAGE_DECODE_ERROR,
                    details=f"Raw data: {data[:100]!r}{'...' if len(data) > 100 else ''}\nJSON Error: {e.msg} at position {e.pos}",
                    suggestion="The server may have sent malformed data. Check server logs for issues.",
                    original_exception=e,
                )
            except UnicodeDecodeError as e:
                raise ProtocolError(
                    message="Failed to decode message as UTF-8",
                    error_code=MonitorErrorCode.MESSAGE_DECODE_ERROR,
                    details=f"Encoding error at position {e.start}-{e.end}",
                    suggestion="The server may be sending data with incorrect encoding.",
                    original_exception=e,
                )

        except asyncio.TimeoutError as e:
            raise ProtocolError(
                message="Timeout waiting for message from server",
                error_code=MonitorErrorCode.CONNECTION_TIMEOUT,
                details="No data received within 30 seconds",
                suggestion="The server may be unresponsive. Check server status and network latency.",
                original_exception=e,
            )

        except ConnectionResetError as e:
            raise ConnectionError(
                message="Connection reset by server",
                error_code=MonitorErrorCode.CONNECTION_CLOSED,
                details="The server unexpectedly closed the connection",
                suggestion="The server may have crashed or been restarted. Try reconnecting.",
                original_exception=e,
            )

        except Exception as e:
            raise ProtocolError(
                message="Error receiving message",
                error_code=MonitorErrorCode.READ_ERROR,
                details=str(e),
                suggestion="Check network connection and server status.",
                original_exception=e,
            )

    async def send_command(self, command: str) -> None:
        """Send a command to the middleware

        Args:
            command: The command string to send

        Raises:
            ClientOperationError: When command cannot be sent
        """
        if not self.writer:
            raise ClientOperationError(
                message="Cannot send command: not connected",
                error_code=MonitorErrorCode.CONNECTION_CLOSED,
                suggestion="Establish a connection before attempting to send commands.",
            )

        try:
            self.writer.write(f"{command}\n".encode("utf-8"))
            await asyncio.wait_for(self.writer.drain(), timeout=10.0)

        except asyncio.TimeoutError as e:
            raise ClientOperationError(
                message="Timeout sending command to server",
                error_code=MonitorErrorCode.CONNECTION_TIMEOUT,
                details=f"Command: {command[:50]}{'...' if len(command) > 50 else ''}",
                suggestion="The server may be overloaded or unresponsive.",
                original_exception=e,
            )

        except ConnectionResetError as e:
            raise ConnectionError(
                message="Connection reset while sending command",
                error_code=MonitorErrorCode.CONNECTION_CLOSED,
                details=f"Command: {command[:50]}{'...' if len(command) > 50 else ''}",
                suggestion="The server closed the connection. Try reconnecting.",
                original_exception=e,
            )

        except BrokenPipeError as e:
            raise ConnectionError(
                message="Broken pipe: connection lost",
                error_code=MonitorErrorCode.CONNECTION_CLOSED,
                details="The connection to the server was lost",
                suggestion="The server may have closed the connection. Try reconnecting.",
                original_exception=e,
            )

        except Exception as e:
            raise ClientOperationError(
                message="Error sending command",
                error_code=MonitorErrorCode.WRITE_ERROR,
                details=f"Command: {command[:50]}{'...' if len(command) > 50 else ''}\nError: {e}",
                suggestion="Check network connection and server status.",
                original_exception=e,
            )

    async def send_json_command(self, command_data: dict) -> None:
        """Send a JSON command to the server

        Args:
            command_data: Dictionary containing the command and parameters

        Raises:
            ClientOperationError: When command cannot be sent
        """
        if not self.writer:
            raise ClientOperationError(
                message="Cannot send command: not connected",
                error_code=MonitorErrorCode.CONNECTION_CLOSED,
                suggestion="Establish a connection before attempting to send commands.",
            )

        try:
            json_str = json.dumps(command_data)
            self.writer.write(f"{json_str}\n".encode("utf-8"))
            await asyncio.wait_for(self.writer.drain(), timeout=10.0)

        except asyncio.TimeoutError as e:
            raise ClientOperationError(
                message="Timeout sending JSON command to server",
                error_code=MonitorErrorCode.CONNECTION_TIMEOUT,
                details=f"Command: {command_data}",
                suggestion="The server may be overloaded or unresponsive.",
                original_exception=e,
            )

        except Exception as e:
            raise ClientOperationError(
                message="Error sending JSON command",
                error_code=MonitorErrorCode.WRITE_ERROR,
                details=f"Command: {command_data}\nError: {e}",
                suggestion="Check network connection and server status.",
                original_exception=e,
            )

    async def stop_process(self, pid: int) -> Optional[dict]:
        """Send stop command for a process

        Args:
            pid: Process ID to stop

        Returns:
            dict: Result from server or None if failed
        """
        try:
            await self.send_json_command({"action": "stop", "pid": pid})
            return {"sent": True, "pid": pid}
        except MonitorClientError as e:
            self.display_error(e)
            return None

    async def start_process(self, command: str) -> Optional[dict]:
        """Send start command to launch a new process

        Args:
            command: Command string to execute

        Returns:
            dict: Result from server or None if failed
        """
        try:
            await self.send_json_command({"action": "start", "command": command})
            return {"sent": True, "command": command}
        except MonitorClientError as e:
            self.display_error(e)
            return None

    async def list_servers(self) -> dict:
        """Get list of available servers

        Returns:
            dict: Dictionary of available servers

        Raises:
            ServerError: When server list cannot be retrieved
        """
        try:
            await self.send_command("LIST")
            response = await self.receive_message()

            if response is None:
                raise ServerError(
                    message="No response received from middleware",
                    error_code=MonitorErrorCode.SERVER_UNAVAILABLE,
                    suggestion="The middleware may have disconnected. Try reconnecting.",
                )

            return response.get("servers", {})

        except MonitorClientError:
            raise  # Re-raise our custom errors
        except Exception as e:
            raise ServerError(
                message="Failed to retrieve server list",
                error_code=MonitorErrorCode.SERVER_UNAVAILABLE,
                details=str(e),
                suggestion="Check middleware connection and try again.",
                original_exception=e,
            )

    def create_system_panel(self, metrics: dict) -> Panel:
        """Create system information panel"""
        system = metrics.get("system", {})

        info_text = Text()
        info_text.append(f"🖥️  {system.get('hostname', 'Unknown')}\n", style="bold cyan")
        info_text.append(
            f"Platform: {system.get('platform', 'Unknown')} {system.get('platform_release', '')}\n"
        )
        info_text.append(f"Architecture: {system.get('architecture', 'Unknown')}\n")
        info_text.append(f"Uptime: {system.get('uptime_formatted', 'Unknown')}\n")
        info_text.append(f"Updated: {datetime.now().strftime('%H:%M:%S')}", style="dim")

        return Panel(
            info_text,
            title="[bold]System Info[/bold]",
            border_style="cyan",
            box=box.ROUNDED,
        )

    def create_cpu_panel(self, metrics: dict) -> Panel:
        """Create CPU metrics panel"""
        cpu = metrics.get("cpu", {})

        # Create CPU usage bars
        usage = cpu.get("usage_total", 0)
        load_avg = cpu.get("load_avg", [0, 0, 0])

        table = Table(show_header=False, box=None, padding=(0, 1))
        table.add_column("Metric", style="cyan")
        table.add_column("Value")

        # Overall usage
        usage_bar = self._create_usage_bar(usage)
        table.add_row("Overall", f"{usage_bar} {usage:.1f}%")

        # Per-core usage
        for i, core_usage in enumerate(
            cpu.get("usage_percent", [])[:4]
        ):  # Show first 4 cores
            core_bar = self._create_usage_bar(core_usage)
            table.add_row(f"Core {i}", f"{core_bar} {core_usage:.1f}%")

        table.add_row("", "")
        table.add_row(
            "Load Avg", f"{load_avg[0]:.2f}, {load_avg[1]:.2f}, {load_avg[2]:.2f}"
        )
        table.add_row(
            "Cores",
            f"{cpu.get('count_logical', 0)} ({cpu.get('count_physical', 0)} physical)",
        )

        return Panel(
            table, title="[bold]CPU[/bold]", border_style="green", box=box.ROUNDED
        )

    def create_memory_panel(self, metrics: dict) -> Panel:
        """Create memory metrics panel"""
        memory = metrics.get("memory", {})
        virtual = memory.get("virtual", {})
        swap = memory.get("swap", {})

        table = Table(show_header=False, box=None, padding=(0, 1))
        table.add_column("Type", style="cyan")
        table.add_column("Usage")

        # RAM
        ram_usage = virtual.get("percent", 0)
        ram_bar = self._create_usage_bar(ram_usage)
        ram_text = (
            f"{virtual.get('used_gb', 0):.1f}GB / {virtual.get('total_gb', 0):.1f}GB"
        )
        table.add_row("RAM", f"{ram_bar} {ram_usage:.1f}%")
        table.add_row("", f"  {ram_text}")

        # Swap
        swap_usage = swap.get("percent", 0)
        swap_bar = self._create_usage_bar(swap_usage)
        swap_text = f"{swap.get('used_gb', 0):.1f}GB / {swap.get('total_gb', 0):.1f}GB"
        table.add_row("Swap", f"{swap_bar} {swap_usage:.1f}%")
        table.add_row("", f"  {swap_text}")

        return Panel(
            table, title="[bold]Memory[/bold]", border_style="yellow", box=box.ROUNDED
        )

    def create_disk_panel(self, metrics: dict) -> Panel:
        """Create disk metrics panel"""
        disk = metrics.get("disk", {})
        partitions = disk.get("partitions", [])[:3]  # Show first 3 partitions

        table = Table(show_header=False, box=None, padding=(0, 1))
        table.add_column("Mount", style="cyan")
        table.add_column("Usage")

        for partition in partitions:
            mount = partition.get("mountpoint", "/")
            usage = partition.get("percent", 0)
            used = partition.get("used_gb", 0)
            total = partition.get("total_gb", 0)

            usage_bar = self._create_usage_bar(usage)
            table.add_row(mount, f"{usage_bar} {usage:.1f}%")
            table.add_row("", f"  {used:.1f}GB / {total:.1f}GB")

        # I/O Stats
        io = disk.get("io", {})
        table.add_row("", "")
        table.add_row("I/O Read", f"{io.get('read_gb', 0):.2f}GB")
        table.add_row("I/O Write", f"{io.get('write_gb', 0):.2f}GB")

        return Panel(
            table, title="[bold]Disk[/bold]", border_style="magenta", box=box.ROUNDED
        )

    def create_network_panel(self, metrics: dict) -> Panel:
        """Create network metrics panel"""
        network = metrics.get("network", {})
        io = network.get("io", {})

        table = Table(show_header=False, box=None, padding=(0, 1))
        table.add_column("Metric", style="cyan")
        table.add_column("Value")

        table.add_row("Sent", f"{io.get('sent_gb', 0):.2f}GB")
        table.add_row("Received", f"{io.get('recv_gb', 0):.2f}GB")
        table.add_row("Connections", str(network.get("connections", 0)))
        table.add_row("Errors In", str(io.get("errin", 0)))
        table.add_row("Errors Out", str(io.get("errout", 0)))

        return Panel(
            table, title="[bold]Network[/bold]", border_style="blue", box=box.ROUNDED
        )

    def create_process_panel(self, metrics: dict) -> Panel:
        """Create top processes panel"""
        processes = metrics.get("top_processes", [])[:10]

        table = Table(show_header=True, box=box.SIMPLE, padding=(0, 1))
        table.add_column("#", style="dim", width=3)
        table.add_column("PID", style="cyan", width=8)
        table.add_column("Name", style="white", width=20)
        table.add_column("CPU%", justify="right", width=8)
        table.add_column("MEM%", justify="right", width=8)
        table.add_column("Status", width=10)

        for idx, proc in enumerate(processes, 1):
            cpu_style = (
                "red"
                if proc["cpu_percent"] > 50
                else "yellow"
                if proc["cpu_percent"] > 20
                else "green"
            )
            mem_style = (
                "red"
                if proc["memory_percent"] > 50
                else "yellow"
                if proc["memory_percent"] > 20
                else "green"
            )

            table.add_row(
                str(idx),
                str(proc["pid"]),
                proc["name"][:20],
                f"[{cpu_style}]{proc['cpu_percent']:.1f}[/{cpu_style}]",
                f"[{mem_style}]{proc['memory_percent']:.1f}[/{mem_style}]",
                proc["status"],
            )

        return Panel(
            table,
            title="[bold]Top Processes[/bold]",
            subtitle="[dim]Press 's' to stop, 'r' to run new[/dim]",
            border_style="white",
            box=box.ROUNDED,
        )

    def create_help_panel(self) -> Panel:
        """Create help panel showing keyboard shortcuts"""
        help_text = Text()
        help_text.append("Keyboard Shortcuts\n\n", style="bold cyan")
        help_text.append("s", style="bold green")
        help_text.append(" - Stop a process (enter PID)\n")
        help_text.append("r", style="bold green")
        help_text.append(" - Run/start a new process\n")
        help_text.append("q", style="bold green")
        help_text.append(" - Quit monitoring\n")
        help_text.append("?", style="bold green")
        help_text.append(" - Show this help\n")

        return Panel(
            help_text,
            title="[bold]Help[/bold]",
            border_style="cyan",
            box=box.ROUNDED,
        )

    def create_notification_panel(self, message: str, is_error: bool = False) -> Panel:
        """Create a notification panel for command results

        Args:
            message: The message to display
            is_error: Whether this is an error message
        """
        style = "red" if is_error else "green"
        return Panel(
            Text(message, style=style),
            title="[bold]Notification[/bold]",
            border_style=style,
            box=box.ROUNDED,
        )

    def _create_usage_bar(self, percentage: float, width: int = 20) -> str:
        """Create a text-based usage bar"""
        filled = int((percentage / 100) * width)
        bar = "█" * filled + "░" * (width - filled)

        if percentage > 80:
            color = "red"
        elif percentage > 60:
            color = "yellow"
        else:
            color = "green"

        return f"[{color}]{bar}[/{color}]"

    def create_dashboard(
        self,
        metrics: dict,
        notification: Optional[str] = None,
        is_error: bool = False,
        interactive: bool = False,
    ) -> Layout:
        """Create the main dashboard layout

        Args:
            metrics: System metrics dictionary
            notification: Optional notification message to display
            is_error: Whether the notification is an error
            interactive: Whether in interactive mode (shows different hint)
        """
        layout = Layout()

        # Split into header, body, and footer
        layout.split_column(
            Layout(name="header", size=7),
            Layout(name="body"),
            Layout(name="footer", size=3),
        )

        # Header
        layout["header"].update(self.create_system_panel(metrics))

        # Body split into left and right
        layout["body"].split_row(Layout(name="left"), Layout(name="right"))

        # Left column
        layout["left"].split_column(
            Layout(name="cpu", size=12),
            Layout(name="memory", size=10),
            Layout(name="network", size=10),
        )

        layout["cpu"].update(self.create_cpu_panel(metrics))
        layout["memory"].update(self.create_memory_panel(metrics))
        layout["network"].update(self.create_network_panel(metrics))

        # Right column
        layout["right"].split_column(
            Layout(name="disk", size=12), Layout(name="processes")
        )

        layout["disk"].update(self.create_disk_panel(metrics))
        layout["processes"].update(self.create_process_panel(metrics))

        # Footer - status bar with shortcuts and notification
        if notification:
            footer_text = Text()
            style = "red" if is_error else "green"
            footer_text.append(f"{notification}", style=style)
        else:
            footer_text = Text()
            if interactive:
                footer_text.append("[m]", style="bold cyan")
                footer_text.append(" Process menu  ")
                footer_text.append("[q]", style="bold yellow")
                footer_text.append(" Quit  ")
                footer_text.append("[s]", style="bold green")
                footer_text.append(" Stop process  ")
                footer_text.append("[r]", style="bold green")
                footer_text.append(" Start process")
            else:
                footer_text.append("[Ctrl+C]", style="bold cyan")
                footer_text.append(" Quit")

        layout["footer"].update(Panel(footer_text, box=box.ROUNDED, border_style="dim"))

        return layout

    async def select_server(self) -> Optional[str]:
        """Interactive server selection

        Returns:
            str: Selected server name or None if cancelled/failed

        Raises:
            ServerError: When server selection fails
        """
        try:
            # Get welcome message
            welcome = await self.receive_message()
            if welcome is None:
                raise ServerError(
                    message="No welcome message received from middleware",
                    error_code=MonitorErrorCode.SERVER_UNAVAILABLE,
                    suggestion="The middleware may have disconnected. Try reconnecting.",
                )

            # Get server list
            server_list_msg = await self.receive_message()
            if server_list_msg is None:
                raise ServerError(
                    message="No server list received from middleware",
                    error_code=MonitorErrorCode.SERVER_UNAVAILABLE,
                    suggestion="The middleware may have disconnected. Try reconnecting.",
                )

            servers = server_list_msg.get("servers", {})

            if not servers:
                error = ServerError(
                    message="No monitoring servers available",
                    error_code=MonitorErrorCode.NO_SERVERS_AVAILABLE,
                    details="The middleware reported no registered servers",
                    suggestion="Ensure at least one monitoring server is running and registered with the middleware.",
                )
                self.display_error(error)
                return None

            # Display server selection
            self.console.clear()
            self.console.print("[bold cyan]Available Servers:[/bold cyan]\n")

            server_names = list(servers.keys())
            for i, server_name in enumerate(server_names, 1):
                server_info = servers[server_name]
                self.console.print(
                    f"  {i}. [green]{server_name}[/green] ({server_info['host']}:{server_info['port']})"
                )

            self.console.print()

            # Get user selection
            while True:
                selection = ""
                try:
                    selection = self.console.input(
                        "[cyan]Select server (number): [/cyan]"
                    )
                    index = int(selection) - 1
                    if 0 <= index < len(server_names):
                        return server_names[index]
                    else:
                        error = ClientOperationError(
                            message="Invalid server selection",
                            error_code=MonitorErrorCode.INVALID_INPUT,
                            details=f"Selection '{selection}' is out of range. Valid range: 1-{len(server_names)}",
                            suggestion=f"Enter a number between 1 and {len(server_names)}.",
                        )
                        self.display_error(error)
                except ValueError:
                    error = ClientOperationError(
                        message="Invalid input: not a number",
                        error_code=MonitorErrorCode.INVALID_INPUT,
                        details=f"Received: '{selection}'",
                        suggestion="Please enter a valid number.",
                    )
                    self.display_error(error)
                except KeyboardInterrupt:
                    return None

        except MonitorClientError as e:
            self.display_error(e)
            return None
        except Exception as e:
            error = ServerError(
                message="Unexpected error during server selection",
                error_code=MonitorErrorCode.UNKNOWN_ERROR,
                details=traceback.format_exc(),
                suggestion="Check middleware connection and try again.",
                original_exception=e,
            )
            self.display_error(error)
            return None

    async def _cleanup_connection(self) -> None:
        """Clean up the connection resources"""
        if self.writer:
            try:
                self.writer.close()
                await self.writer.wait_closed()
            except Exception:
                pass  # Ignore cleanup errors
        self.connected = False
        self.writer = None
        self.reader = None

    def _setup_terminal(self) -> None:
        """Set up terminal for non-blocking key input"""
        if sys.stdin.isatty():
            self._old_terminal_settings = termios.tcgetattr(sys.stdin)
            tty.setcbreak(sys.stdin.fileno())

    def _restore_terminal(self) -> None:
        """Restore terminal to original settings"""
        if self._old_terminal_settings is not None:
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, self._old_terminal_settings)
            self._old_terminal_settings = None

    def _check_keypress(self) -> Optional[str]:
        """Check for a keypress without blocking"""
        if sys.stdin.isatty():
            import select

            if select.select([sys.stdin], [], [], 0)[0]:
                return sys.stdin.read(1)
        return None

    async def prompt_stop_process(self) -> Optional[int]:
        """Prompt user for PID to stop

        Returns:
            int: PID to stop or None if cancelled
        """
        self.console.print("\n[bold cyan]Stop Process[/bold cyan]")
        self.console.print("Enter the PID of the process to stop (or 'c' to cancel):")

        try:
            user_input = self.console.input("[cyan]PID: [/cyan]").strip()

            if user_input.lower() == "c":
                return None

            pid = int(user_input)
            return pid
        except ValueError:
            self.console.print("[red]Invalid PID. Please enter a number.[/red]")
            return None
        except KeyboardInterrupt:
            return None

    async def prompt_start_process(self) -> Optional[str]:
        """Prompt user for command to start

        Returns:
            str: Command to execute or None if cancelled
        """
        self.console.print("\n[bold cyan]Start Process[/bold cyan]")
        self.console.print("Enter the command to run (or 'c' to cancel):")

        try:
            command = self.console.input("[cyan]Command: [/cyan]").strip()

            if command.lower() == "c" or not command:
                return None

            return command
        except KeyboardInterrupt:
            return None

    async def interactive_monitor(self) -> None:
        """Interactive monitoring with process control

        This is an alternative monitoring mode that allows keyboard interaction
        """
        if not await self.connect():
            return

        try:
            # Select server
            server_name = await self.select_server()
            if not server_name:
                error = ClientOperationError(
                    message="No server selected",
                    error_code=MonitorErrorCode.OPERATION_CANCELLED,
                    suggestion="Run the monitor again and select a server to monitor.",
                )
                self.display_error(error)
                return

            # Connect to selected server
            try:
                await self.send_command(f"CONNECT {server_name}")
            except MonitorClientError as e:
                self.display_error(e)
                return

            # Wait for connection confirmation
            try:
                response = await self.receive_message()
            except MonitorClientError as e:
                self.display_error(e)
                return

            if response is None:
                error = ServerError(
                    message=f"No response when connecting to server '{server_name}'",
                    error_code=MonitorErrorCode.SERVER_CONNECTION_FAILED,
                    suggestion="The server may be unavailable. Try selecting another server.",
                )
                self.display_error(error)
                return

            if response.get("type") != "connected":
                error_msg = response.get("error", "Unknown error")
                error = ServerError(
                    message=f"Failed to connect to monitoring server '{server_name}'",
                    error_code=MonitorErrorCode.SERVER_CONNECTION_FAILED,
                    details=f"Server response: {error_msg}",
                    suggestion="The server may be busy or unavailable. Try again or select another server.",
                )
                self.display_error(error)
                return

            self.server_name = server_name

            # Show interactive menu
            await self._run_interactive_loop()

        except KeyboardInterrupt:
            pass
        finally:
            self._restore_terminal()
            self.console.clear()
            if self.server_name:
                self.console.print(
                    f"[yellow]Disconnected from {self.server_name}[/yellow]"
                )
            await self._cleanup_connection()

    async def _run_interactive_loop(self) -> None:
        """Run the interactive monitoring loop with menu"""
        notification: Optional[str] = None
        notification_is_error: bool = False

        self._setup_terminal()

        try:
            with Live(console=self.console, refresh_per_second=2, screen=True) as live:
                while True:
                    # Check for keypress
                    key = self._check_keypress()
                    if key:
                        if key.lower() == "m":
                            # Show menu
                            self._restore_terminal()
                            live.stop()
                            await self._show_command_menu()
                            self._setup_terminal()
                            live.start()
                        elif key.lower() == "q":
                            # Quit
                            break
                        elif key.lower() == "s":
                            # Stop process
                            self._restore_terminal()
                            live.stop()
                            pid = await self.prompt_stop_process()
                            if pid is not None:
                                result = await self.stop_process(pid)
                                if result:
                                    notification = f"Stop command sent for PID {pid}"
                                    notification_is_error = False
                                else:
                                    notification = f"Failed to send stop command"
                                    notification_is_error = True
                            self._setup_terminal()
                            live.start()
                        elif key.lower() == "r":
                            # Start process
                            self._restore_terminal()
                            live.stop()
                            command = await self.prompt_start_process()
                            if command is not None:
                                result = await self.start_process(command)
                                if result:
                                    notification = f"Start command sent: {command}"
                                    notification_is_error = False
                                else:
                                    notification = f"Failed to send start command"
                                    notification_is_error = True
                            self._setup_terminal()
                            live.start()

                    # Receive messages with short timeout
                    try:
                        message = await asyncio.wait_for(
                            self.receive_message(), timeout=0.1
                        )
                    except asyncio.TimeoutError:
                        message = None
                    except (ProtocolError, ConnectionError) as e:
                        self._restore_terminal()
                        live.stop()
                        self.display_error(e)
                        break

                    # Process message
                    if message:
                        if message.get("type") == "metrics":
                            self.current_metrics = message.get("data")
                        elif message.get("type") == "command_result":
                            if message.get("success"):
                                notification = message.get(
                                    "message", "Command executed successfully"
                                )
                                notification_is_error = False
                            else:
                                notification = message.get("error", "Command failed")
                                notification_is_error = True
                        elif message.get("type") == "error":
                            notification = message.get("message", "Server error")
                            notification_is_error = True

                    # Update display
                    if self.current_metrics:
                        dashboard = self.create_dashboard(
                            self.current_metrics,
                            notification,
                            notification_is_error,
                            interactive=True,
                        )
                        live.update(dashboard)

        except KeyboardInterrupt:
            # Ctrl+C now just quits
            pass
        finally:
            self._restore_terminal()

    async def _show_command_menu(self) -> None:
        """Show interactive command menu"""
        self.console.clear()

        while True:
            self.console.print("\n[bold cyan]Process Management Menu[/bold cyan]")
            self.console.print("-" * 30)
            self.console.print("1. [green]Stop[/green] a process")
            self.console.print("2. [green]Start[/green] a new process")
            self.console.print("3. [yellow]Return[/yellow] to monitoring")
            self.console.print("4. [red]Quit[/red]")
            self.console.print()

            try:
                choice = self.console.input(
                    "[cyan]Select option (1-4): [/cyan]"
                ).strip()

                if choice == "1":
                    pid = await self.prompt_stop_process()
                    if pid is not None:
                        result = await self.stop_process(pid)
                        if result:
                            self.console.print(
                                f"[green]Stop command sent for PID {pid}[/green]"
                            )
                            # Wait a moment to receive the result
                            try:
                                response = await asyncio.wait_for(
                                    self.receive_message(), timeout=2.0
                                )
                                if (
                                    response
                                    and response.get("type") == "command_result"
                                ):
                                    if response.get("success"):
                                        self.console.print(
                                            f"[green]{response.get('message')}[/green]"
                                        )
                                    else:
                                        self.console.print(
                                            f"[red]Error: {response.get('error')}[/red]"
                                        )
                            except asyncio.TimeoutError:
                                pass
                            # Prompt to continue
                            self.console.input(
                                "\n[dim]Press Enter to continue...[/dim]"
                            )

                elif choice == "2":
                    command = await self.prompt_start_process()
                    if command is not None:
                        result = await self.start_process(command)
                        if result:
                            self.console.print(
                                f"[green]Start command sent: {command}[/green]"
                            )
                            # Wait a moment to receive the result
                            try:
                                response = await asyncio.wait_for(
                                    self.receive_message(), timeout=2.0
                                )
                                if (
                                    response
                                    and response.get("type") == "command_result"
                                ):
                                    if response.get("success"):
                                        self.console.print(
                                            f"[green]{response.get('message')}[/green]"
                                        )
                                    else:
                                        self.console.print(
                                            f"[red]Error: {response.get('error')}[/red]"
                                        )
                            except asyncio.TimeoutError:
                                pass
                            # Prompt to continue
                            self.console.input(
                                "\n[dim]Press Enter to continue...[/dim]"
                            )

                elif choice == "3":
                    # Return to monitoring
                    return

                elif choice == "4":
                    # Quit - raise exception to exit the whole program
                    raise KeyboardInterrupt()

                else:
                    self.console.print("[red]Invalid option. Please select 1-4.[/red]")

            except KeyboardInterrupt:
                raise

    async def monitor(self) -> None:
        """Main monitoring loop

        Raises:
            MonitorClientError: Various errors during monitoring
        """
        if not await self.connect():
            return

        try:
            # Select server
            server_name = await self.select_server()
            if not server_name:
                error = ClientOperationError(
                    message="No server selected",
                    error_code=MonitorErrorCode.OPERATION_CANCELLED,
                    suggestion="Run the monitor again and select a server to monitor.",
                )
                self.display_error(error)
                return

            # Connect to selected server
            try:
                await self.send_command(f"CONNECT {server_name}")
            except MonitorClientError as e:
                self.display_error(e)
                return

            # Wait for connection confirmation
            try:
                response = await self.receive_message()
            except MonitorClientError as e:
                self.display_error(e)
                return

            if response is None:
                error = ServerError(
                    message=f"No response when connecting to server '{server_name}'",
                    error_code=MonitorErrorCode.SERVER_CONNECTION_FAILED,
                    suggestion="The server may be unavailable. Try selecting another server.",
                )
                self.display_error(error)
                return

            if response.get("type") != "connected":
                error_msg = response.get("error", "Unknown error")
                error = ServerError(
                    message=f"Failed to connect to monitoring server '{server_name}'",
                    error_code=MonitorErrorCode.SERVER_CONNECTION_FAILED,
                    details=f"Server response: {error_msg}",
                    suggestion="The server may be busy or unavailable. Try again or select another server.",
                )
                self.display_error(error)
                return

            self.server_name = server_name
            self.console.clear()

            # Notification state
            notification: Optional[str] = None
            notification_is_error: bool = False
            notification_clear_time: Optional[float] = None

            # Start monitoring loop with live updates
            try:
                with Live(
                    console=self.console, refresh_per_second=1, screen=True
                ) as live:
                    while True:
                        try:
                            # Use a short timeout to allow checking for keyboard input
                            message = await asyncio.wait_for(
                                self.receive_message(), timeout=0.5
                            )
                        except asyncio.TimeoutError:
                            # No message received, continue to update display
                            message = None
                        except ProtocolError as e:
                            self.display_error(e)
                            break
                        except ConnectionError as e:
                            self.display_error(e)
                            break

                        # Clear notification after 5 seconds
                        if (
                            notification_clear_time
                            and asyncio.get_event_loop().time()
                            > notification_clear_time
                        ):
                            notification = None
                            notification_is_error = False
                            notification_clear_time = None

                        if message is None:
                            # Just update the display with current metrics
                            if self.current_metrics:
                                dashboard = self.create_dashboard(
                                    self.current_metrics,
                                    notification,
                                    notification_is_error,
                                )
                                live.update(dashboard)
                            continue

                        if message.get("type") == "metrics":
                            self.current_metrics = message.get("data")
                            if self.current_metrics:
                                dashboard = self.create_dashboard(
                                    self.current_metrics,
                                    notification,
                                    notification_is_error,
                                )
                                live.update(dashboard)
                        elif message.get("type") == "command_result":
                            # Handle command result from server
                            if message.get("success"):
                                notification = message.get(
                                    "message", "Command executed successfully"
                                )
                                notification_is_error = False
                            else:
                                notification = message.get("error", "Command failed")
                                notification_is_error = True
                            notification_clear_time = (
                                asyncio.get_event_loop().time() + 5
                            )
                        elif message.get("type") == "error":
                            error = ServerError(
                                message=f"Server error received",
                                error_code=MonitorErrorCode.SERVER_UNAVAILABLE,
                                details=message.get("message", "Unknown server error"),
                                suggestion="Check server logs for more details.",
                            )
                            self.display_error(error)
                            break

            except KeyboardInterrupt:
                pass  # Normal exit via Ctrl+C
            except Exception as e:
                error = MonitorClientError(
                    message="Unexpected error during monitoring",
                    error_code=MonitorErrorCode.UNKNOWN_ERROR,
                    details=traceback.format_exc(),
                    suggestion="Please report this issue if it persists.",
                    original_exception=e,
                )
                self.display_error(error)

        finally:
            self.console.clear()
            if self.server_name:
                self.console.print(
                    f"[yellow]Disconnected from {self.server_name}[/yellow]"
                )
            await self._cleanup_connection()


async def main():
    """Main entry point"""
    import sys

    middleware_host = os.getenv("MIDDLEWARE_HOST", "localhost")
    middleware_port = int(os.getenv("MIDDLEWARE_PORT", 9000))

    client = MonitoringClient(middleware_host, middleware_port)

    # Check for interactive mode flag
    if "--interactive" in sys.argv or "-i" in sys.argv:
        await client.interactive_monitor()
    else:
        await client.monitor()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nExiting...")
