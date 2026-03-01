"""
Middleware Proxy Server
Routes client connections to appropriate monitoring servers
Provides server discovery and connection management
"""

import asyncio
import json
import os
from typing import Dict, Set, Optional
from datetime import datetime


class ServerRegistry:
    """Manages available monitoring servers"""

    def __init__(self):
        self.servers: Dict[str, Dict] = {}
        self.lock = asyncio.Lock()

    async def register_server(self, server_name: str, host: str, port: int):
        """Register a monitoring server"""
        async with self.lock:
            self.servers[server_name] = {
                "host": host,
                "port": port,
                "registered_at": datetime.now().isoformat(),
                "status": "active",
            }
            print(f"[REGISTRY] Registered server: {server_name} at {host}:{port}")

    async def unregister_server(self, server_name: str):
        """Unregister a monitoring server"""
        async with self.lock:
            if server_name in self.servers:
                del self.servers[server_name]
                print(f"[REGISTRY] Unregistered server: {server_name}")

    async def get_server(self, server_name: str) -> Optional[Dict]:
        """Get server information"""
        async with self.lock:
            return self.servers.get(server_name)

    async def list_servers(self) -> Dict[str, Dict]:
        """List all registered servers"""
        async with self.lock:
            return self.servers.copy()


class MiddlewareProxy:
    """Proxy server that routes client requests to monitoring servers"""

    def __init__(self, host: str = "0.0.0.0", port: int = 9000):
        self.host = host
        self.port = port
        self.registry = ServerRegistry()
        self.clients: Set[asyncio.StreamWriter] = set()

    async def initialize_servers(self):
        """Initialize known servers from environment"""
        # Parse SERVER_LIST environment variable
        # Format: "server1:host1:port1,server2:host2:port2"
        server_list = os.getenv("SERVER_LIST", "")

        if server_list:
            for server_entry in server_list.split(","):
                parts = server_entry.strip().split(":")
                if len(parts) == 3:
                    name, host, port = parts
                    await self.registry.register_server(name, host, int(port))

        # Also check for individual server environment variables
        for env_var in os.environ:
            if env_var.startswith("MONITOR_SERVER_"):
                server_info = os.getenv(env_var)
                if server_info:
                    parts = server_info.split(":")
                    if len(parts) == 3:
                        name, host, port = parts
                        await self.registry.register_server(name, host, int(port))

    async def proxy_data(
        self, server_reader: asyncio.StreamReader, client_writer: asyncio.StreamWriter
    ):
        """Proxy data from server to client"""
        try:
            while True:
                data = await server_reader.readline()
                if not data:
                    break

                try:
                    client_writer.write(data)
                    await client_writer.drain()
                except (ConnectionResetError, BrokenPipeError):
                    # Client disconnected
                    break

        except (ConnectionResetError, BrokenPipeError):
            # Connection closed
            pass
        except Exception as e:
            print(f"[ERROR] Proxy error: {e}")

    async def proxy_commands(
        self, client_reader: asyncio.StreamReader, server_writer: asyncio.StreamWriter
    ):
        """Proxy commands from client to server"""
        try:
            while True:
                data = await client_reader.readline()
                if not data:
                    break

                try:
                    server_writer.write(data)
                    await server_writer.drain()
                except (ConnectionResetError, BrokenPipeError):
                    # Server disconnected
                    break

        except (ConnectionResetError, BrokenPipeError):
            # Connection closed
            pass
        except asyncio.CancelledError:
            pass
        except Exception as e:
            print(f"[ERROR] Command proxy error: {e}")

    async def bidirectional_proxy(
        self,
        client_reader: asyncio.StreamReader,
        client_writer: asyncio.StreamWriter,
        server_reader: asyncio.StreamReader,
        server_writer: asyncio.StreamWriter,
    ):
        """Proxy data bidirectionally between client and server"""
        # Create tasks for both directions
        server_to_client = asyncio.create_task(
            self.proxy_data(server_reader, client_writer)
        )
        client_to_server = asyncio.create_task(
            self.proxy_commands(client_reader, server_writer)
        )

        # Wait for either direction to complete
        done, pending = await asyncio.wait(
            [server_to_client, client_to_server], return_when=asyncio.FIRST_COMPLETED
        )

        # Cancel the remaining task
        for task in pending:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

    async def connect_to_server(self, server_name: str) -> Optional[tuple]:
        """Connect to a monitoring server"""
        server_info = await self.registry.get_server(server_name)

        if not server_info:
            return None

        try:
            reader, writer = await asyncio.open_connection(
                server_info["host"], server_info["port"]
            )

            # Send auth token if configured
            auth_token = os.getenv("AUTH_TOKEN")
            if auth_token:
                auth_msg = {"action": "AUTH", "token": auth_token}
                writer.write(json.dumps(auth_msg).encode() + b"\n")
                await writer.drain()

            return reader, writer
        except Exception as e:
            print(f"[ERROR] Failed to connect to {server_name}: {e}")
            return None

    async def handle_client(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ):
        """Handle client connections"""
        addr = writer.get_extra_info("peername")
        print(f"[INFO] Client connected: {addr}")
        self.clients.add(writer)

        try:
            # Send welcome message
            welcome = {
                "type": "welcome",
                "message": "Connected to monitoring middleware",
                "commands": [
                    "LIST - List available servers",
                    "CONNECT <server_name> - Connect to a server",
                    "QUIT - Disconnect",
                ],
                "process_commands": [
                    "STOP <pid> - Stop a process by PID (after connected to server)",
                    "START <command> - Start a new process (after connected to server)",
                ],
            }
            writer.write(json.dumps(welcome).encode() + b"\n")
            await writer.drain()

            # Send server list
            servers = await self.registry.list_servers()
            server_list = {"type": "server_list", "servers": servers}
            writer.write(json.dumps(server_list).encode() + b"\n")
            await writer.drain()

            # Wait for client command
            while True:
                try:
                    data = await reader.readline()
                    if not data:
                        break
                except ConnectionResetError:
                    break
                except Exception as e:
                    print(f"[ERROR] Read error: {e}")
                    break

                try:
                    command = data.decode().strip()

                    if command.upper() == "LIST":
                        servers = await self.registry.list_servers()
                        response = {"type": "server_list", "servers": servers}
                        writer.write(json.dumps(response).encode() + b"\n")
                        await writer.drain()

                    elif command.upper().startswith("CONNECT "):
                        server_name = command.split()[1]

                        # Connect to the requested server
                        connection = await self.connect_to_server(server_name)

                        if connection:
                            server_reader, server_writer = connection

                            # Send confirmation
                            response = {
                                "type": "connected",
                                "server_name": server_name,
                                "message": f"Connected to {server_name}",
                            }
                            writer.write(json.dumps(response).encode() + b"\n")
                            await writer.drain()

                            # Start bidirectional proxying
                            await self.bidirectional_proxy(
                                reader, writer, server_reader, server_writer
                            )

                            # Cleanup server connection
                            try:
                                server_writer.close()
                                await server_writer.wait_closed()
                            except Exception:
                                pass
                            break
                        else:
                            error = {
                                "type": "error",
                                "message": f"Failed to connect to {server_name}",
                            }
                            writer.write(json.dumps(error).encode() + b"\n")
                            await writer.drain()

                    elif command.upper() == "QUIT":
                        break

                    else:
                        error = {
                            "type": "error",
                            "message": "Unknown command. Use LIST, CONNECT <server>, or QUIT",
                        }
                        writer.write(json.dumps(error).encode() + b"\n")
                        await writer.drain()

                except Exception as e:
                    print(f"[ERROR] Command processing error: {e}")
                    error = {"type": "error", "message": str(e)}
                    writer.write(json.dumps(error).encode() + b"\n")
                    await writer.drain()

        except Exception as e:
            print(f"[ERROR] Client {addr} error: {e}")
        finally:
            print(f"[INFO] Client disconnected: {addr}")
            self.clients.discard(writer)
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                # Ignore errors during cleanup - connection already closed
                pass

    async def start(self):
        """Start the middleware proxy"""
        await self.initialize_servers()

        server = await asyncio.start_server(self.handle_client, self.host, self.port)

        addr = server.sockets[0].getsockname()
        print(f"[INFO] Middleware proxy started on {addr}")
        print(
            f"[INFO] Registered servers: {list((await self.registry.list_servers()).keys())}"
        )

        async with server:
            await server.serve_forever()


async def main():
    """Main entry point"""
    port = int(os.getenv("MIDDLEWARE_PORT", 9000))

    print("[STARTUP] Initializing middleware proxy...")
    proxy = MiddlewareProxy(port=port)

    try:
        await proxy.start()
    except KeyboardInterrupt:
        print("\n[SHUTDOWN] Middleware shutting down...")


if __name__ == "__main__":
    asyncio.run(main())
