# docker-update
A script that simplifies running docker compose updates.


docker-update.sh
 Pull the latest images for all services in a Docker Compose file,
 recreate changed containers, and clean up dangling images / old layers
 if everything succeeds.

 Usage:
   ./docker-update.sh [OPTIONS] [COMPOSE_FILE]

 Arguments:
   COMPOSE_FILE   Path to docker-compose file (default: auto-detects compose.yml
                  or docker-compose.yml in the current directory)

 Options:
   -h, --help     Show this help message
   -d, --dry-run  Show what would happen without making any changes
   -y, --yes      Skip confirmation prompts (non-interactive / CI mode)
   -p, --prune    Also run a full system prune (containers, images, networks,
                  volumes, and build cache) after a successful update
   -r, --recreate Force recreate all containers, even if nothing has changed
