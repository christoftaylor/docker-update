#!/bin/sh
# =============================================================================
# docker-update.sh
# Pull the latest images for all services in a Docker Compose file,
# recreate changed containers, and clean up dangling objects if
# everything succeeds.
#
# Usage:
#   ./docker-update.sh [OPTIONS] [COMPOSE_FILE]
#
# Arguments:
#   COMPOSE_FILE   Path to docker-compose file (default: auto-detects compose.yml
#                  or docker-compose.yml in the current directory)
#
# Options:
#   -h, --help     Show this help message
#   -d, --dry-run  Show what would happen without making any changes
#   -y, --yes      Skip confirmation prompts (non-interactive / CI mode)
#   -p, --prune    Also run a full system prune (containers, images, networks,
#                  volumes, and build cache) after a successful update
#   -r, --recreate Force recreate all containers, even if nothing has changed
# =============================================================================

set -eu

# ── Colours ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { printf "${CYAN}[INFO]${RESET}  %s\n" "$*"; }
success() { printf "${GREEN}[OK]${RESET}    %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
error()   { printf "${RED}[ERROR]${RESET} %s\n" "$*" >&2; }
die()     { error "$*"; exit 1; }

separator() { printf "${BOLD}──────────────────────────────────────────────────${RESET}\n"; }

usage() {
  echo ""
  awk '/^# ={10}/{found++; next} found==1{sub(/^# ?/,""); print} found==2{exit}' "$0"
  echo ""
  exit 0
}

confirm() {
  prompt="${1:-Continue?}"
  if [ "$YES" = true ]; then return 0; fi
  printf "${YELLOW}%s [y/N]: ${RESET}" "$prompt"
  read -r answer
  answer=$(echo "$answer" | tr '[:upper:]' '[:lower:]')
  [ "$answer" = "y" ] || [ "$answer" = "yes" ]
}

# ── Defaults ──────────────────────────────────────────────────────────────────
COMPOSE_FILE=""
DRY_RUN=false
YES=false
PRUNE_VOLUMES=false
FORCE_RECREATE=false

# ── Argument parsing ──────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)     usage ;;
    -d|--dry-run)  DRY_RUN=true;        shift ;;
    -y|--yes)      YES=true;            shift ;;
    -p|--prune)    PRUNE_VOLUMES=true;  shift ;;
    -r|--recreate) FORCE_RECREATE=true; shift ;;
    -*)            die "Unknown option: $1" ;;
    *)             COMPOSE_FILE="$1";   shift ;;
  esac
done

# ── Auto-detect compose file if not supplied ──────────────────────────────────
if [ -z "$COMPOSE_FILE" ]; then
  if [ -f "compose.yml" ]; then
    COMPOSE_FILE="compose.yml"
  elif [ -f "docker-compose.yml" ]; then
    COMPOSE_FILE="docker-compose.yml"
  else
    die "No compose file found. Expected 'compose.yml' or 'docker-compose.yml' in the current directory, or pass a path explicitly."
  fi
fi

# ── Preflight checks ──────────────────────────────────────────────────────────
separator
info "Docker Compose Update Script"
separator

[ -f "$COMPOSE_FILE" ] || die "Compose file not found: $COMPOSE_FILE"

command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH"

# Detect compose command (plugin vs standalone)
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  die "Neither 'docker compose' nor 'docker-compose' is available"
fi

printf "${CYAN}[INFO]${RESET}  Compose command : ${BOLD}%s${RESET}\n" "$DC"
printf "${CYAN}[INFO]${RESET}  Compose file    : ${BOLD}%s${RESET}\n" "$COMPOSE_FILE"
printf "${CYAN}[INFO]${RESET}  Dry run         : ${BOLD}%s${RESET}\n" "$DRY_RUN"
printf "${CYAN}[INFO]${RESET}  Force recreate  : ${BOLD}%s${RESET}\n" "$FORCE_RECREATE"
printf "${CYAN}[INFO]${RESET}  Full prune      : ${BOLD}%s${RESET}\n" "$PRUNE_VOLUMES"

# ── run_cmd: print and optionally execute a command ──────────────────────────
# Usage: run_cmd "Description" "full command string"
run_cmd() {
  desc="$1"
  cmd="$2"
  if [ "$DRY_RUN" = true ]; then
    info "Would run: $cmd"
  else
    info "Running: $cmd"
    eval "$cmd" || die "$desc failed."
  fi
}

if [ "$DRY_RUN" = true ]; then
  separator
  warn "DRY RUN — no changes will be made."
fi

# ── Step 1: Pull latest images ────────────────────────────────────────────────
separator
info "Step 1/3 — Pulling latest images…"

confirm "Pull new images for all services?" || { info "Aborted."; exit 0; }

run_cmd "Image pull" "$DC -f $COMPOSE_FILE pull"

[ "$DRY_RUN" = false ] && success "All images pulled successfully."

# ── Step 2: Recreate containers ───────────────────────────────────────────────
separator
if [ "$FORCE_RECREATE" = true ]; then
  info "Step 2/3 — Force recreating all containers…"
else
  info "Step 2/3 — Recreating changed containers…"
fi

confirm "Bring services up and remove any orphans?" || { info "Aborted."; exit 0; }

UP_CMD="$DC -f $COMPOSE_FILE up -d --remove-orphans"
if [ "$FORCE_RECREATE" = true ]; then
  UP_CMD="$UP_CMD --force-recreate"
fi

run_cmd "Container recreation" "$UP_CMD"

[ "$DRY_RUN" = false ] && success "All services are up."

# ── Verify containers are healthy / running ───────────────────────────────────
if [ "$DRY_RUN" = false ]; then
  info "Verifying container states…"

  FAILED_CONTAINERS=""
  PS_OUTPUT=$($DC -f "$COMPOSE_FILE" ps --format "{{.Name}} {{.State}}" 2>/dev/null || \
              $DC -f "$COMPOSE_FILE" ps | tail -n +3 | awk '{print $1, $4}')

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    name=$(echo "$line" | awk '{print $1}')
    state=$(echo "$line" | awk '{print $2}')
    if [ "$state" != "running" ]; then
      FAILED_CONTAINERS="${FAILED_CONTAINERS}  • ${name} (${state})\n"
    fi
  done << EOF
$PS_OUTPUT
EOF

  if [ -n "$FAILED_CONTAINERS" ]; then
    error "The following containers are NOT running after the update:"
    printf "${RED}%b${RESET}" "$FAILED_CONTAINERS" >&2
    warn "Skipping cleanup — resolve the issues above first."
    exit 1
  fi

  success "All containers are running."
fi

# ── Step 3: Clean up ──────────────────────────────────────────────────────────
separator
info "Step 3/3 — Cleaning up…"

if [ "$PRUNE_VOLUMES" = true ]; then
  CLEAN_CMD="docker system prune -af --volumes"
  confirm "Remove all unused containers, volumes, images, networks, and build chache? (THIS IS DESTRUCTIVE)" || { warn "Skipped system prune."; CLEAN_CMD=""; }
else
  CLEAN_CMD="docker image prune -f"
  confirm "Remove any images no longer in use after this update?" || { warn "Skipped image prune."; CLEAN_CMD=""; }
fi

if [ -n "$CLEAN_CMD" ]; then
  run_cmd "Cleanup" "$CLEAN_CMD"
  [ "$DRY_RUN" = false ] && success "Cleanup complete."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
separator
if [ "$DRY_RUN" = true ]; then
  success "Dry run complete."
else
  success "Update complete! Summary:"
  $DC -f "$COMPOSE_FILE" ps
fi
separator

