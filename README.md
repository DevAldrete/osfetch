# OS Monitoring System with Process Control

A distributed server monitoring system built with Python, featuring real-time metrics visualization and remote process management.

## Features

- 🖥️ **Real-time System Monitoring**: CPU, memory, disk, network, and process metrics
- 🎮 **Process Control**: Start and stop processes remotely on monitored servers
- 🌐 **Multi-Server Support**: Monitor multiple servers through a central middleware
- 🎨 **Rich Terminal UI**: Beautiful, interactive dashboard using Rich library
- 🐳 **Docker-Ready**: Fully containerized with Docker Compose
- ⚡ **Async Architecture**: Built with asyncio for high performance

## Quick Start

```bash
# 1. Start all services
./run.sh start

# 2. Run the monitoring client
./run.sh interactive

# 3. Select a server and start monitoring!
```

## Two Client Modes

### View-Only Mode

```bash
./run.sh client
```

- Display real-time metrics
- No process control
- Ctrl+C to quit

### Interactive Mode (Recommended)

```bash
./run.sh interactive
```

- Display real-time metrics
- **Start processes**: Launch new processes remotely
- **Stop processes**: Terminate processes by PID
- Ctrl+C for menu, then choose actions

## Process Control

In interactive mode, press **Ctrl+C** to open the menu:

```
Process Management Menu
------------------------------
1. Stop a process      → Enter PID to terminate
2. Start a new process → Enter command to launch
3. Return to monitoring
4. Quit
```

### Examples

**Stop a process:**

1. Note the PID from the "Top Processes" panel
2. Press Ctrl+C
3. Choose option 1
4. Enter the PID

**Start a process:**

1. Press Ctrl+C
2. Choose option 2
3. Enter command (e.g., `sleep 300`, `python script.py`)

## Commands

```bash
./run.sh start        # Start all services
./run.sh stop         # Stop all services
./run.sh restart      # Restart everything
./run.sh client       # Run client (view-only)
./run.sh interactive  # Run client with process control
./run.sh status       # Check service status
./run.sh logs         # View logs
./run.sh build        # Rebuild Docker images
./run.sh clean        # Remove all containers
```

## Architecture

```
Client (Terminal UI)
      ↕
Middleware (Proxy/Router)
      ↕
Servers (Metric Collection + Process Control)
```

**Components:**

- **Server** (`server/`): Collects system metrics using psutil, handles process operations
- **Middleware** (`middleware/`): Routes client connections to appropriate servers
- **Client** (`client/`): Rich terminal UI for visualization and control

## Requirements

- Docker & Docker Compose
- Python 3.11+ (for local development)
- Terminal with UTF-8 support (for UI)

## Documentation

- **[QUICKSTART.md](QUICKSTART.md)**: Step-by-step setup guide
- **[PROCESS_CONTROL.md](PROCESS_CONTROL.md)**: Complete process control documentation
- **[HOW_TO_USE.txt](HOW_TO_USE.txt)**: Quick reference card
- **[AGENTS.md](AGENTS.md)**: Guidelines for AI coding assistants

## Technology Stack

- **Python 3.11+**: Core language
- **asyncio**: Asynchronous I/O for networking
- **psutil**: System and process metrics collection
- **Rich**: Terminal UI framework
- **Docker**: Containerization
- **Docker Compose**: Multi-container orchestration

## Security Note

⚠️ **Process control provides significant system access**. In production:

- Add authentication
- Log all process control actions
- Restrict allowed commands (whitelist)
- Use Docker security features (user namespaces, capabilities)

## Development

### Local Development (without Docker)

```bash
# Install dependencies
pip install -r requirements.txt

# Terminal 1 - Start server
cd server && python monitor_server.py

# Terminal 2 - Start middleware
cd middleware && python proxy.py

# Terminal 3 - Run client
cd client && python monitor_client.py --interactive
```

### Project Structure

```
/
├── server/              # Monitoring server
│   ├── monitor_server.py
│   ├── pyproject.toml
│   └── Dockerfile
├── middleware/          # Proxy/router
│   ├── proxy.py
│   ├── pyproject.toml
│   └── Dockerfile
├── client/              # Terminal UI
│   ├── monitor_client.py
│   ├── pyproject.toml
│   └── Dockerfile
├── docker-compose.yml   # Service orchestration
├── run.sh               # Convenience script
└── requirements.txt     # Python dependencies
```

## Testing

```bash
# Run the test suite
./test_process_control.sh

# This will:
# - Check if services are running
# - Verify capabilities
# - Create test processes
# - Validate process visibility
```

## Troubleshooting

**Can't see process control menu?**

- Use `./run.sh interactive` (not `./run.sh client`)

**"Process not found" error?**

- Verify the PID from the Top Processes panel
- Process may have already terminated

**"Access denied" when stopping process?**

- Process belongs to another user
- Check the username column in Top Processes

**"Command not found" when starting?**

- Use full path: `/usr/bin/python` instead of `python`
- Command may not be available in the container

## Performance

Each component uses minimal resources:

- CPU: < 1%
- Memory: ~30-50MB per container
- Network: ~5KB/s per connection

## License

[Add your license here]

## Contributing

[Add contribution guidelines here]

## Support

For issues and questions, please [open an issue](your-repo-url).

---

**Made with ❤️ using Python and Docker**
