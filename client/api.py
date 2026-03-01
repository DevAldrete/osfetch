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
