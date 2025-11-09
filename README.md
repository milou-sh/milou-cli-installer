# Milou CLI

```
 __  __ ___ _     ___  _   _ 
|  \/  |_ _| |   |_ _|| \ | |
| |\/| || || |    | | |  \| |
| |  | || || |___ | | | |\  |
|_|  |_|___|_____|___||_| \_|

  ____ _     ___ 
 / ___| |   |_ _|
| |   | |    | | 
| |___| |___ | | 
 \____|_____|___|
```

Secure, scripted operations tooling for the Milou platform. The CLI itself is open source; Milou services stay proprietary and ship as GHCR images behind authentication.

This repository contains **only** the installer, bash modules, and sample docker-compose definitions. The Milou applications and databases remain closed-source artifacts distributed through GHCR once you authenticate.

- Hardened bash modules for setup, secrets management, SSL, Docker, GHCR, and backups
- Single entrypoint (`milou`) with consistent UX for operators and CI
- Works on any modern Linux host with Docker Engine + docker compose plugin installed

> 📘 Full product documentation (architecture, domain specifics, onboarding) lives in the public docs site at https://docs.milou.sh. This README focuses on running the installer + CLI.

---

## Contents

1. [Requirements](#requirements)
2. [Installation](#installation)
3. [Quick Usage](#quick-usage)
4. [.env & Secrets](#env--secrets)
5. [Docker Compose Layout](#docker-compose-layout)
6. [Advanced Commands](#advanced-commands)
7. [Troubleshooting](#troubleshooting)
8. [Project Status & Support](#project-status--support)
9. [License](#license)

## Requirements

| Component | Details |
|-----------|---------|
| OS | 64-bit Linux with bash 4+, systemd recommended |
| CLI tooling | `curl`, `tar`, `jq`, `openssl`, and `sudo` available in `$PATH` |
| Docker | Docker Engine 24+ and docker compose plugin (the installer can auto-install on Debian/Ubuntu) |
| Network | Outbound HTTPS to `github.com` + `ghcr.io` |
| Credentials | *Required*: GitHub PAT with `read:packages` scope to pull Milou GHCR images |
| Disk | ~5 GB for images + volumes |

## Installation

### System install (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/milou-sh/milou-cli-installer/main/install.sh | sudo bash
```

- Installs into `/opt/milou`
- Creates service user `milou` and wrapper `/usr/local/bin/milou`
- Ensures Docker Engine + compose plugin exist (auto-installs on Debian/Ubuntu)
- Verify downloads with the SHA256 checksum published alongside every GitHub release.

### Custom install (non-root)

```bash
MILOU_INSTALL_DIR="$HOME/milou" \
curl -fsSL https://raw.githubusercontent.com/milou-sh/milou-cli-installer/main/install.sh | bash
```

Adds the target directory to your shell `PATH` so you can run `milou` directly.

> ℹ️ Need to run completely unprivileged? Download the tarball attached to every GitHub release and unpack it anywhere on your `$PATH`, then invoke `./milou setup --yes` with the required `MILOU_SETUP_*` values.

## Open Source vs Proprietary Assets

| Area | Status | Notes |
|------|--------|-------|
| Installer CLI (`milou`, `lib/*.sh`, `install.sh`) | Open source (MIT) | Maintained in this repo |
| Docker Compose files | Open source | Reference layouts; feel free to fork |
| Milou application images (`ghcr.io/milou-sh/milou/*`) | Proprietary | Requires paid subscription + PAT |
| Documentation portal | Public | https://docs.milou.sh |
| Commercial support playbooks | Proprietary | Available through your contract |

## Quick Usage

```bash
milou setup          # Interactive wizard (creates .env, SSL, GHCR token prompts)
milou start          # Start all Milou services via docker compose
milou status         # docker compose ps with health reporting
milou logs backend   # Tail service logs
milou update         # Pull tagged images, run DB migrations, restart
```

- Use `milou setup --yes` with `MILOU_SETUP_*` env vars for unattended installs
- `milou ghcr setup` stores/validates a PAT; without it you cannot pull Milou images
- All file operations are atomic and re-apply `600` for `.env`/secrets automatically

## .env & Secrets

- Copy `.env.template` or rerun `milou setup` to regenerate
- Required values: `DOMAIN`, `ADMIN_EMAIL`, `GHCR_TOKEN`, database + queue creds
- CLI auto-generates random passwords and JWT/crypto secrets when missing
- `.env` permissions are enforced at `600`; SSL private keys live in `ssl/key.pem` (also `600`)

### GHCR authentication

```bash
MILOU_SETUP_GHCR_TOKEN=ghp_xxx milou setup --yes
milou ghcr login            # Re-authenticate using token from .env
milou ghcr status           # Check docker config auth state
```

Milou images remain private. Without a valid PAT, compose commands will fail during the pull stage.

## Docker Compose Layout

The CLI ships three compose files under the project root:

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Default stack (Traefik-ready) with database, queue, backend, frontend, docs, engine |
| `docker-compose.prod.yml` | Production-safe variant with the same GHCR images but minimal host ports |
| `docker-compose.dev.yml` | Developer convenience profile that publishes friendly host ports |
| `docker-compose.override.example.yml` | Sample Traefik override referencing `demo.milou.sh`

All service containers use the published Milou GHCR images:

```yaml
backend:
  image: ghcr.io/milou-sh/milou/backend:${MILOU_VERSION:-latest}
  env_file:
    - ./.env
```

Supply `MILOU_VERSION` (via `.env` or `milou config set`) to pin a release. `milou check-updates` compares your version with the latest GitHub release tag.

## Advanced Commands

| Command | Description |
|---------|-------------|
| `milou config get|set|show|validate` | Safe .env operations with atomic writes |
| `milou ssl generate|import|info|renew` | Self-signed or imported cert management (permissions enforced) |
| `milou backup [name]` / `milou restore <name>` | tar.gz backups containing `.env`, SSL, and compose files |
| `milou docker pull|build|clean|logs` | Direct Docker helpers using the same compose stack |
| `milou db migrate` | Runs the migration profile (database-migrations service) |
| `milou version show|latest|check` | Reads local version, queries GitHub releases, suggests updates |

## Troubleshooting

- **Docker not running** → `sudo systemctl start docker` then retry `milou start`
- **GHCR auth failures** → `milou ghcr status`, ensure PAT has `read:packages`, rerun `milou ghcr login`
- **Permission denied on .env** → `sudo chown milou:milou /opt/milou/.env && chmod 600 /opt/milou/.env`
- **Compose network `proxy` missing** → `docker network create proxy` or drop the override file referencing it
- **Database migrations failed** → inspect `docker compose logs database-migrations`; rerun after fixing credentials

## Project Status & Support

- CLI code: open source in this repository (MIT)
- Milou platform services/images: closed source, distributed via GHCR (paid)
- Documentation & onboarding guides: https://docs.milou.sh
- Security policy: [SECURITY.md](SECURITY.md)
- Support tiers: [SUPPORT.md](SUPPORT.md)

For help:
1. Run `milou help`
2. Check `milou logs`
3. Review `.env` + SSL permissions
4. Open a GitHub issue (community)
5. Contact the Milou team through your commercial support channel (customers)

## License

Milou CLI is released under the [MIT License](LICENSE). Copy it, fork it, or wire it into your automation—just don’t expect the proprietary Milou services to run without a valid subscription.
