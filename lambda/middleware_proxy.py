"""
Lambda Middleware Proxy — WebSocket edition
============================================
Implements the same logical role as middleware/proxy.py but adapted for
AWS Lambda + API Gateway WebSocket API.

Architecture
------------
                                            VPC
  Client (TUI)                           ┌──────────────────────────────┐
      │                                  │                              │
      │  WebSocket (wss://<apigw>)       │  TCP :9001                   │
      └──────────► API GW ──────────────►│  Lambda ──────────────────►  │
                  WebSocket              │  (VPC-attached)   server EC2 │
                                         └──────────────────────────────┘

Lambda constraints vs. proxy.py
---------------------------------
proxy.py holds a *persistent* bidirectional TCP connection and forwards bytes
in real time.  Lambda is invoked per-event and has no persistent state between
invocations.  The adaptation works as follows:

1. The server registry is static — loaded from the SERVER_LIST environment
   variable at cold-start (same format as middleware/proxy.py).

2. Each connected WebSocket client is identified by its `connectionId` from
   API GW.  A connection table is kept in a module-level dict (warm Lambda
   instance cache); this is best-effort — a cold start loses in-flight state,
   but for a lab environment this is acceptable.

3. Message flow for CONNECT <name>:
     a. Lambda looks up the target server's host:port.
     b. Opens a TCP socket to the server (synchronous, inside the handler).
     c. Reads the server handshake and relays it back to the client via
        the API GW Management API (POST /@connections/<connectionId>).
     d. Starts a background asyncio loop to drain the server socket and
        push each metrics line back to the client via API GW.
     e. Commands from the client arrive as WebSocket messages and are
        forwarded directly to the open TCP socket.

4. Because Lambda invocations are short-lived (max 15 min) the background
   drain loop runs inside the same invocation's event loop for the duration
   of the connection.  This is intentionally simpler than proxy.py and suits
   the lab context.

Environment variables (same names as proxy.py):
  SERVER_LIST          — "name:host:port,name:host:port,..."
  MIDDLEWARE_PORT      — ignored (API GW handles the port)
  AWS_REGION           — set automatically by the Lambda runtime
  APIGW_ENDPOINT       — set by Terraform to the Management API URL
                         e.g. https://<api-id>.execute-api.<region>.amazonaws.com/<stage>
"""

from __future__ import annotations

import asyncio
import json
import os
import socket
import urllib.request
from typing import Dict, Optional, Tuple

# ── Server registry ───────────────────────────────────────────
# Loaded once at cold-start; each entry: {"host": str, "port": int}
_registry: Dict[str, Dict] = {}


def _load_registry() -> None:
    """Parse SERVER_LIST env var and populate the module-level registry."""
    server_list = os.getenv("SERVER_LIST", "")
    for entry in server_list.split(","):
        entry = entry.strip()
        if not entry:
            continue
        parts = entry.split(":")
        if len(parts) == 3:
            name, host, port_str = parts
            _registry[name] = {"host": host, "port": int(port_str)}

    # Also support individual MONITOR_SERVER_* env vars
    for key, value in os.environ.items():
        if key.startswith("MONITOR_SERVER_") and value:
            parts = value.split(":")
            if len(parts) == 3:
                name, host, port_str = parts
                _registry[name] = {"host": host, "port": int(port_str)}


_load_registry()

# ── In-process connection table (warm-instance cache) ─────────
# Maps connectionId → open socket.  Lost on cold start (acceptable for lab).
_connections: Dict[str, socket.socket] = {}


# ── API GW Management API helper ─────────────────────────────


def _apigw_endpoint() -> str:
    return os.environ["APIGW_ENDPOINT"].rstrip("/")


def _send_to_client(connection_id: str, payload: bytes) -> None:
    """POST a message back to the WebSocket client via API GW Management API.

    Args:
        connection_id: The API GW connectionId for this client.
        payload: Raw bytes to deliver (should be valid JSON + newline).
    """
    url = f"{_apigw_endpoint()}/@connections/{connection_id}"
    req = urllib.request.Request(
        url,
        data=payload,
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=5):
            pass
    except Exception as e:
        print(f"[ERROR] Failed to send to client {connection_id}: {e}")


def _disconnect_client(connection_id: str) -> None:
    """Close and clean up the server TCP socket for a given connection."""
    sock = _connections.pop(connection_id, None)
    if sock:
        try:
            sock.close()
        except Exception:
            pass


# ── TCP helpers ───────────────────────────────────────────────


def _open_server_socket(host: str, port: int, timeout: float = 10.0) -> socket.socket:
    """Open a blocking TCP socket to a monitoring server.

    Args:
        host: Hostname or IP of the monitoring server.
        port: TCP port (default 9001).
        timeout: Connection timeout in seconds.

    Returns:
        Connected socket object.

    Raises:
        OSError: If the connection fails.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect((host, port))
    return sock


def _readline(sock: socket.socket, max_bytes: int = 65536) -> bytes:
    """Read one newline-terminated line from a blocking socket.

    Args:
        sock: Connected TCP socket.
        max_bytes: Safety limit to avoid unbounded reads.

    Returns:
        The line including the trailing newline, or b"" on EOF.
    """
    buf = bytearray()
    while len(buf) < max_bytes:
        chunk = sock.recv(1)
        if not chunk:
            return bytes(buf)
        buf += chunk
        if buf.endswith(b"\n"):
            return bytes(buf)
    return bytes(buf)


def _send_line(sock: socket.socket, data: bytes) -> None:
    """Send data to the server socket, appending a newline if absent.

    Args:
        sock: Connected TCP socket.
        data: Data to send (JSON-encoded command bytes).
    """
    if not data.endswith(b"\n"):
        data = data + b"\n"
    sock.sendall(data)


# ── Lambda handlers ───────────────────────────────────────────


def handler(event: dict, context) -> dict:
    """Main Lambda entry point — routes API GW WebSocket events.

    API GW sends three route keys:
      $connect    — new WebSocket client connected
      $disconnect — client disconnected
      $default    — any other message frame from the client

    Args:
        event: Lambda event dict from API GW WebSocket.
        context: Lambda context (unused).

    Returns:
        API GW response dict with statusCode.
    """
    route_key = event.get("requestContext", {}).get("routeKey", "$default")
    connection_id: str = event["requestContext"]["connectionId"]

    if route_key == "$connect":
        return _handle_connect(connection_id)
    elif route_key == "$disconnect":
        return _handle_disconnect(connection_id)
    else:
        body = event.get("body", "") or ""
        return _handle_message(connection_id, body)


def _handle_connect(connection_id: str) -> dict:
    """Send welcome + server_list to a freshly connected WebSocket client.

    Args:
        connection_id: API GW connectionId.

    Returns:
        HTTP 200 response.
    """
    welcome = {
        "type": "welcome",
        "message": "Connected to osfetch Lambda middleware",
        "commands": [
            "LIST - List available servers",
            "CONNECT <server_name> - Connect to a server",
            "QUIT - Disconnect",
        ],
    }
    _send_to_client(connection_id, json.dumps(welcome).encode() + b"\n")

    server_list = {
        "type": "server_list",
        "servers": {
            name: {"host": info["host"], "port": info["port"], "status": "active"}
            for name, info in _registry.items()
        },
    }
    _send_to_client(connection_id, json.dumps(server_list).encode() + b"\n")
    return {"statusCode": 200}


def _handle_disconnect(connection_id: str) -> dict:
    """Clean up server socket on client disconnect.

    Args:
        connection_id: API GW connectionId.

    Returns:
        HTTP 200 response.
    """
    _disconnect_client(connection_id)
    print(f"[INFO] Client disconnected: {connection_id}")
    return {"statusCode": 200}


def _handle_message(connection_id: str, body: str) -> dict:
    """Process a message frame from the WebSocket client.

    Supports three command types:
      LIST                    — re-send server_list
      CONNECT <server_name>   — open TCP connection and start streaming
      QUIT                    — close connection
      <JSON object>           — forward as process command to connected server

    Args:
        connection_id: API GW connectionId.
        body: Raw message body from the WebSocket frame.

    Returns:
        HTTP 200 response.
    """
    command = body.strip()

    # ── LIST ──────────────────────────────────────────────────
    if command.upper() == "LIST":
        server_list = {
            "type": "server_list",
            "servers": {
                name: {"host": info["host"], "port": info["port"], "status": "active"}
                for name, info in _registry.items()
            },
        }
        _send_to_client(connection_id, json.dumps(server_list).encode() + b"\n")
        return {"statusCode": 200}

    # ── QUIT ──────────────────────────────────────────────────
    if command.upper() == "QUIT":
        _disconnect_client(connection_id)
        return {"statusCode": 200}

    # ── JSON process command (STOP / START) ───────────────────
    if command.startswith("{"):
        sock = _connections.get(connection_id)
        if not sock:
            _send_to_client(
                connection_id,
                json.dumps(
                    {"type": "error", "message": "Not connected to a server"}
                ).encode()
                + b"\n",
            )
            return {"statusCode": 200}
        try:
            _send_line(sock, command.encode())
            # Read one response line from the server and relay it
            response_line = _readline(sock)
            if response_line:
                _send_to_client(connection_id, response_line)
        except Exception as e:
            _send_to_client(
                connection_id,
                json.dumps({"type": "error", "message": f"Server error: {e}"}).encode()
                + b"\n",
            )
        return {"statusCode": 200}

    # ── CONNECT <name> ────────────────────────────────────────
    if command.upper().startswith("CONNECT "):
        parts = command.split(None, 1)
        if len(parts) < 2:
            _send_to_client(
                connection_id,
                json.dumps(
                    {"type": "error", "message": "Usage: CONNECT <server_name>"}
                ).encode()
                + b"\n",
            )
            return {"statusCode": 200}

        server_name = parts[1].strip()
        server_info = _registry.get(server_name)
        if not server_info:
            _send_to_client(
                connection_id,
                json.dumps(
                    {
                        "type": "error",
                        "message": f"Server '{server_name}' not found in registry",
                    }
                ).encode()
                + b"\n",
            )
            return {"statusCode": 200}

        # Close any existing server connection for this client
        _disconnect_client(connection_id)

        try:
            sock = _open_server_socket(server_info["host"], server_info["port"])
        except OSError as e:
            _send_to_client(
                connection_id,
                json.dumps(
                    {
                        "type": "error",
                        "message": f"Cannot reach server '{server_name}': {e}",
                    }
                ).encode()
                + b"\n",
            )
            return {"statusCode": 200}

        _connections[connection_id] = sock

        # Notify client that the tunnel is open
        _send_to_client(
            connection_id,
            json.dumps(
                {
                    "type": "connected",
                    "server_name": server_name,
                    "message": f"Connected to {server_name}",
                }
            ).encode()
            + b"\n",
        )

        # Read the server handshake and relay it
        handshake = _readline(sock)
        if handshake:
            _send_to_client(connection_id, handshake)

        # Stream metrics: read lines from the server and push to the client.
        # We stay in this loop until:
        #   a. The server closes the connection (empty readline)
        #   b. The socket times out (recv raises OSError)
        #   c. We exhaust the Lambda function timeout (AWS kills the invocation)
        #
        # For a lab this is simple and effective.  For production you would use
        # SQS / DynamoDB Streams to decouple the polling from the invocation.
        sock.settimeout(2.5)  # slightly longer than the server's 2 s push interval
        while True:
            try:
                line = _readline(sock)
                if not line:
                    break
                _send_to_client(connection_id, line)
            except socket.timeout:
                # No data within 2.5 s — server is slow; keep waiting
                continue
            except OSError:
                break

        # Server closed the connection
        _disconnect_client(connection_id)
        _send_to_client(
            connection_id,
            json.dumps(
                {"type": "disconnected", "message": "Server closed the connection"}
            ).encode()
            + b"\n",
        )
        return {"statusCode": 200}

    # ── Unknown command ───────────────────────────────────────
    _send_to_client(
        connection_id,
        json.dumps(
            {
                "type": "error",
                "message": "Unknown command. Use LIST, CONNECT <server>, or QUIT",
            }
        ).encode()
        + b"\n",
    )
    return {"statusCode": 200}
