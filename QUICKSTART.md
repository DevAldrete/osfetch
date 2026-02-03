# Quick Start Guide

Get up and running with the Server Monitoring System in 5 minutes.

## Prerequisites

- Docker installed
- Docker Compose installed
- Terminal access

## Step 1: Setup (30 seconds)

```bash
# Create project directory
mkdir server-monitoring && cd server-monitoring

# Place all files in this structure:
# .
# ├── docker-compose.yml
# ├── run.sh
# ├── server/
# │   ├── Dockerfile
# │   ├── requirements.txt
# │   └── monitor_server.py
# ├── middleware/
# │   ├── Dockerfile
# │   ├── requirements.txt
# │   └── proxy.py
# └── client/
#     ├── Dockerfile
#     ├── requirements.txt
#     └── monitor_client.py

# Make run script executable
chmod +x run.sh
```

## Step 2: Start Services (1 minute)

```bash
# Start all monitoring servers and middleware
./run.sh start
```

You should see:

```
Starting monitoring infrastructure...
✓ Services started successfully!

Available servers:
monitor-server1    running
monitor-server2    running
monitor-server3    running
```

## Step 3: Run Client (30 seconds)

```bash
# Launch the monitoring client
./run.sh client
```

You'll see a menu:

```
Available Servers:

  1. server1 (server1:9001)
  2. server2 (server2:9001)
  3. server3 (server3:9001)

Select server (number):
```

Type `1` and press Enter.

## Step 4: Monitor! 🎉

You'll see a live dashboard with:

- System information (hostname, uptime, platform)
- CPU usage (overall and per-core)
- Memory usage (RAM and swap)
- Disk usage and I/O
- Network statistics
- Top processes by CPU/memory

Press `Ctrl+C` to exit.

## Common Commands

```bash
./run.sh start        # Start all services
./run.sh stop         # Stop all services
./run.sh client       # Run the monitoring client (view only)
./run.sh interactive  # Run client with process control (start/stop processes)
./run.sh status       # Check service status
./run.sh logs         # View logs
./run.sh restart      # Restart everything
./run.sh clean        # Remove all containers
```

## Process Management (Interactive Mode)

To start and stop processes on monitored servers:

```bash
./run.sh interactive
```

Once connected to a server:
1. **Press Ctrl+C** to open the process management menu
2. Choose from:
   - **Stop a process**: Enter a PID to terminate it (sends SIGTERM, then SIGKILL if needed)
   - **Start a process**: Enter a command to launch (e.g., `sleep 100`, `python script.py`)
   - **Return to monitoring**: Go back to the live dashboard
   - **Quit**: Exit the client

The dashboard shows top processes by CPU usage - note the PIDs to stop specific processes.

## Customization

### Add More Servers

Edit `docker-compose.yml`:

```yaml
  server4:
    build:
      context: ./server
      dockerfile: Dockerfile
    container_name: monitor-server4
    environment:
      - SERVER_NAME=database-server
      - SERVER_PORT=9001
    networks:
      - monitoring-network
```

Update middleware SERVER_LIST:

```yaml
  middleware:
    environment:
      - SERVER_LIST=server1:server1:9001,server2:server2:9001,server3:server3:9001,server4:server4:9001
```

Then restart:

```bash
./run.sh restart
```

### Monitor Host System

To monitor your actual computer instead of the container, edit `docker-compose.yml`:

```yaml
  server1:
    # ... existing config ...
    privileged: true
    pid: "host"
```

⚠️ **Warning**: Only use in trusted environments!

## Troubleshooting

### "Port already in use"

```bash
# Check what's using port 9000
lsof -i :9000

# Or change the port in docker-compose.yml
ports:
  - "9999:9000"  # Use 9999 instead
```

### Services won't start

```bash
# Check Docker is running
docker ps

# View detailed logs
./run.sh logs
```

### Can't connect to servers

```bash
# Verify services are running
./run.sh status

# Restart everything
./run.sh restart
```

### Metrics not updating

- Wait 2-3 seconds for initial data
- Check network connectivity
- Verify server logs: `docker logs monitor-server1`

## Next Steps

1. **Explore the Dashboard**: Try different servers
2. **Check the Logs**: Use `./run.sh logs` to see system activity
3. **Customize Metrics**: Edit `monitor_server.py` to add custom metrics
4. **Build Extensions**: Add authentication, databases, web UI

## Architecture Overview

```
[Your Computer]
      │
      ├─ Docker Network (monitoring-network)
      │
      ├─ Middleware (Port 9000)
      │   └─ Routes connections
      │
      ├─ Server 1 (Port 9001)
      │   └─ Collects metrics
      │
      ├─ Server 2 (Port 9001)
      │   └─ Collects metrics
      │
      └─ Server 3 (Port 9001)
          └─ Collects metrics

[Client connects to Middleware → Middleware routes to selected Server]
```

## What Each Component Does

- **Client**: Pretty terminal UI you interact with
- **Middleware**: Smart router that connects you to the right server
- **Servers**: Collect and stream system metrics

## Performance

Each component uses minimal resources:

- CPU: < 1%
- Memory: ~30-50MB per container
- Network: ~5KB/s per connection

Perfect for development and production!

---

**🎯 Pro Tip**: Keep the client running in one terminal and `./run.sh logs` in another to see what's happening behind the scenes.

**🚀 You're all set!** Enjoy monitoring your systems.
