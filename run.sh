# Server Monitoring System - Startup Script
# This script helps you easily manage the monitoring system

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════╗"
echo "║   Server Monitoring System Manager       ║"
echo "╚═══════════════════════════════════════════╝"
echo -e "${NC}"

show_usage() {
  echo "Usage: ./run.sh [command]"
  echo ""
  echo "Commands:"
  echo "  start       - Start all monitoring servers and middleware"
  echo "  stop        - Stop all services"
  echo "  restart     - Restart all services"
  echo "  client      - Run the monitoring client (view only)"
  echo "  interactive - Run client with process control (start/stop processes)"
  echo "  logs        - Show logs from all services"
  echo "  status      - Show status of all services"
  echo "  build       - Rebuild all Docker images"
  echo "  clean       - Stop and remove all containers and networks"
  echo "  help        - Show this help message"
}

start_services() {
  echo -e "${GREEN}Starting monitoring infrastructure...${NC}"
  docker-compose up -d
  echo ""
  echo -e "${GREEN}✓ Services started successfully!${NC}"
  echo ""
  echo "Available servers:"
  docker-compose ps | grep server
  echo ""
  echo -e "${YELLOW}Run './run.sh client' to connect to a server${NC}"
}

stop_services() {
  echo -e "${YELLOW}Stopping all services...${NC}"
  docker-compose down
  echo -e "${GREEN}✓ Services stopped${NC}"
}

restart_services() {
  stop_services
  sleep 2
  start_services
}

run_client() {
  echo -e "${GREEN}Starting monitoring client...${NC}"
  echo -e "${YELLOW}Press Ctrl+C to exit${NC}"
  echo ""
  docker-compose run --rm client
}

run_interactive_client() {
  echo -e "${GREEN}Starting interactive monitoring client...${NC}"
  echo -e "${YELLOW}Features: View metrics + Start/Stop processes${NC}"
  echo -e "${YELLOW}Press Ctrl+C to open process management menu${NC}"
  echo ""
  docker-compose run --rm client python monitor_client.py --interactive
}

show_logs() {
  echo -e "${GREEN}Showing logs (Ctrl+C to exit)...${NC}"
  docker-compose logs -f
}

show_status() {
  echo -e "${GREEN}Service Status:${NC}"
  echo ""
  docker-compose ps
  echo ""

  echo -e "${GREEN}Network Information:${NC}"
  docker network inspect monitoring-network --format '{{range .Containers}}{{.Name}}: {{.IPv4Address}}{{"\n"}}{{end}}' 2>/dev/null || echo "Network not created yet"
}

build_images() {
  echo -e "${GREEN}Building Docker images...${NC}"
  docker-compose build --no-cache
  echo -e "${GREEN}✓ Build complete${NC}"
}

clean_all() {
  echo -e "${RED}This will remove all containers, networks, and volumes.${NC}"
  read -p "Are you sure? (y/N) " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Cleaning up...${NC}"
    docker-compose down -v
    docker network rm monitoring-network 2>/dev/null || true
    echo -e "${GREEN}✓ Cleanup complete${NC}"
  else
    echo "Cancelled"
  fi
}

# Main command handler
case "${1}" in
start)
  start_services
  ;;
stop)
  stop_services
  ;;
restart)
  restart_services
  ;;
client)
  run_client
  ;;
interactive | i)
  run_interactive_client
  ;;
logs)
  show_logs
  ;;
status)
  show_status
  ;;
build)
  build_images
  ;;
clean)
  clean_all
  ;;
help | --help | -h)
  show_usage
  ;;
*)
  if [ -z "$1" ]; then
    show_usage
  else
    echo -e "${RED}Unknown command: $1${NC}"
    echo ""
    show_usage
    exit 1
  fi
  ;;
esac
