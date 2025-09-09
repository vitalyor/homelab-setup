#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Homelab setup script for Ubuntu Server + minimal GNOME + Docker stack
# Author: ChatGPT
# Tested for Ubuntu 22.04/24.04
# =============================================================================

# -------- Helpers --------
log() { echo -e "\n\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\n\033[1;33m[!]\033[0m $*"; }
err() { echo -e "\n\033[1;31m[x]\033[0m $*"; }

RELEASE_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"

# -------- 0) Sudo check --------
if [[ $EUID -ne 0 ]]; then
  err "Run as root: sudo bash setup_homelab.sh"
  exit 1
fi

# -------- 1) Basics --------
log "Updating system and installing base packages..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl gnupg lsb-release \
  build-essential git wget unzip jq tmux htop ufw \
  python3 python3-venv python3-pip \
  openssh-server

# Timezone & locale
log "Configuring timezone and locale..."
timedatectl set-timezone Europe/Moscow
apt-get install -y locales
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

# -------- 2) Minimal GNOME + Cockpit --------
log "Installing minimal GNOME (ubuntu-desktop-minimal) and Cockpit..."
DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-desktop-minimal
DEBIAN_FRONTEND=noninteractive apt-get install -y cockpit
systemctl enable --now cockpit

# -------- 3) Prevent sleep on lid close --------
log "Disabling suspend on lid close..."
sed -i 's/^#\?HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
sed -i 's/^#\?HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/' /etc/systemd/logind.conf
systemctl restart systemd-logind || true

# -------- 4) Unattended security upgrades --------
log "Enabling unattended-upgrades (security only)..."
DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades
dpkg-reconfigure -plow unattended-upgrades
cat >/etc/apt/apt.conf.d/51auto-reboot <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF

# -------- 5) Docker Engine + Compose --------
log "Installing Docker Engine + Compose plugin..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  ${RELEASE_CODENAME} stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

# Allow current sudo user to use Docker without sudo
PRIMARY_USER="$(logname 2>/dev/null || echo ${SUDO_USER:-})"
if [[ -n "$PRIMARY_USER" ]]; then
  usermod -aG docker "$PRIMARY_USER" || true
fi

# -------- 6) NVIDIA drivers + nvidia-container-toolkit --------
log "Installing NVIDIA drivers + nvidia-container-toolkit..."

# Рекомендуемый драйвер (если уже стоит — пропустит)
apt-get install -y ubuntu-drivers-common
ubuntu-drivers autoinstall || true

# Репозиторий NVIDIA Container Toolkit — корректный для Ubuntu 22.04
distribution=$(. /etc/os-release; echo ${ID}${VERSION_ID})

# Ключ репозитория
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

# Подключение репозитория (важно: $distribution, а не "stable")
curl -fsSL https://nvidia.github.io/libnvidia-container/${distribution}/libnvidia-container.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get update -y
apt-get install -y nvidia-container-toolkit

# Настройка Docker под NVIDIA
nvidia-ctk runtime configure --runtime=docker || true
systemctl restart docker || true

# -------- 7) NVM + Node LTS --------
log "Installing nvm and Node.js LTS..."
sudo -u "$PRIMARY_USER" bash -lc 'export PROFILE="$HOME/.bashrc"; \
  if ! command -v nvm >/dev/null 2>&1; then \
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash; \
  fi; \
  source "$HOME/.nvm/nvm.sh"; \
  nvm install --lts; nvm alias default lts/*; node -v; npm -v'

# -------- 8) UFW basic rules --------
log "Configuring UFW firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 9090/tcp
ufw allow 80/tcp
ufw --force enable

# -------- 9) Compose stack: Traefik + Portainer + DBs + Admin UIs + Netdata --------
log "Creating /srv/homelab stack..."

mkdir -p /srv/homelab/traefik
cd /srv/homelab

PGADMIN_PASS="$(openssl rand -hex 12)"
ME_PASS="$(openssl rand -hex 12)"
POSTGRES_PASS="$(openssl rand -hex 16)"
MONGO_EXPRESS_USER="admin"
ADMIN_EMAIL="admin@example.com"
SERVER_IP_PLACEHOLDER="REPLACE_ME_WITH_SERVER_IP"

cat > .env <<EOV
SERVER_IP=${SERVER_IP_PLACEHOLDER}
ADMIN_EMAIL=${ADMIN_EMAIL}

POSTGRES_PASSWORD=${POSTGRES_PASS}
PGADMIN_DEFAULT_EMAIL=${ADMIN_EMAIL}
PGADMIN_DEFAULT_PASSWORD=${PGADMIN_PASS}

ME_CONFIG_BASICAUTH_USERNAME=${MONGO_EXPRESS_USER}
ME_CONFIG_BASICAUTH_PASSWORD=${ME_PASS}

REDIS_COMMANDER_HTTP_USER=
REDIS_COMMANDER_HTTP_PASSWORD=
EOV

cat > docker-compose.yml <<'EOC'
version: "3.9"

networks:
  proxy:
    driver: bridge

volumes:
  portainer_data:
  pg_data:
  redis_data:
  mongo_data:
  netdata_lib:
  netdata_cache:

services:

  traefik:
    image: traefik:v3.1
    container_name: traefik
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --entrypoints.web.address=:80
    ports:
      - "80:80"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - proxy
    restart: unless-stopped

  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    labels:
      - traefik.enable=true
      - traefik.http.routers.portainer.rule=Host(`portainer.${SERVER_IP}.nip.io`)
      - traefik.http.routers.portainer.entrypoints=web
      - traefik.http.services.portainer.loadbalancer.server.port=9000
    networks:
      - proxy
    restart: unless-stopped

  postgres:
    image: postgres:16
    container_name: postgres
    environment:
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - pg_data:/var/lib/postgresql/data
    restart: unless-stopped

  redis:
    image: redis:latest
    container_name: redis
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - redis_data:/data
    restart: unless-stopped

  mongo:
    image: mongo:latest
    container_name: mongo
    volumes:
      - mongo_data:/data/db
    restart: unless-stopped

  pgadmin:
    image: dpage/pgadmin4:latest
    container_name: pgadmin
    environment:
      - PGADMIN_DEFAULT_EMAIL=${PGADMIN_DEFAULT_EMAIL}
      - PGADMIN_DEFAULT_PASSWORD=${PGADMIN_DEFAULT_PASSWORD}
    depends_on:
      - postgres
    labels:
      - traefik.enable=true
      - traefik.http.routers.pgadmin.rule=Host(`pgadmin.${SERVER_IP}.nip.io`)
      - traefik.http.routers.pgadmin.entrypoints=web
      - traefik.http.services.pgadmin.loadbalancer.server.port=80
    networks:
      - proxy
    restart: unless-stopped

  redis-commander:
    image: rediscommander/redis-commander:latest
    container_name: redis-commander
    environment:
      - REDIS_HOSTS=local:redis:6379
      - HTTP_USER=${REDIS_COMMANDER_HTTP_USER}
      - HTTP_PASSWORD=${REDIS_COMMANDER_HTTP_PASSWORD}
    depends_on:
      - redis
    labels:
      - traefik.enable=true
      - traefik.http.routers.rediscomm.rule=Host(`redis.${SERVER_IP}.nip.io`)
      - traefik.http.routers.rediscomm.entrypoints=web
      - traefik.http.services.rediscomm.loadbalancer.server.port=8081
    networks:
      - proxy
    restart: unless-stopped

  mongo-express:
    image: mongo-express:latest
    container_name: mongo-express
    environment:
      - ME_CONFIG_MONGODB_SERVER=mongo
      - ME_CONFIG_BASICAUTH_USERNAME=${ME_CONFIG_BASICAUTH_USERNAME}
      - ME_CONFIG_BASICAUTH_PASSWORD=${ME_CONFIG_BASICAUTH_PASSWORD}
    depends_on:
      - mongo
    labels:
      - traefik.enable=true
      - traefik.http.routers.mexpress.rule=Host(`mongo.${SERVER_IP}.nip.io`)
      - traefik.http.routers.mexpress.entrypoints=web
      - traefik.http.services.mexpress.loadbalancer.server.port=8081
    networks:
      - proxy
    restart: unless-stopped

  netdata:
    image: netdata/netdata:stable
    container_name: netdata
    pid: host
    cap_add:
      - SYS_PTRACE
    security_opt:
      - apparmor:unconfined
    volumes:
      - netdata_lib:/var/lib/netdata
      - netdata_cache:/var/cache/netdata
      - /etc/passwd:/host/etc/passwd:ro
      - /etc/group:/host/etc/group:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /etc/os-release:/host/etc/os-release:ro
    labels:
      - traefik.enable=true
      - traefik.http.routers.netdata.rule=Host(`netdata.${SERVER_IP}.nip.io`)
      - traefik.http.routers.netdata.entrypoints=web
      - traefik.http.services.netdata.loadbalancer.server.port=19999
    networks:
      - proxy
    restart: unless-stopped
EOC

# -------- 10) Final messages --------
log "All set. Next steps:"
cat <<'NEXT'

1) Reboot:
   sudo reboot

2) Edit /srv/homelab/.env:
   - Set SERVER_IP to your LAN IP (e.g., 192.168.1.50)
   - Set ADMIN_EMAIL to your email

3) Bring up the stack:
   cd /srv/homelab
   docker compose up -d

4) Access services:
   - Portainer:      http://portainer.<IP>.nip.io
   - pgAdmin:        http://pgadmin.<IP>.nip.io
   - Redis Commander:http://redis.<IP>.nip.io
   - Mongo Express:  http://mongo.<IP>.nip.io
   - Netdata:        http://netdata.<IP>.nip.io
   - Cockpit:        https://<IP>:9090
NEXT

log "Done."
