#!/usr/bin/env bash
# AgentOZ Cloud Agent install: durable dependency setup after checkout.
# Idempotent: safe to run repeatedly and against cached state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NACOS_VERSION="2.3.2"
NACOS_HOME="$HOME/nacos"

echo "==> [1/6] Installing system packages"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  openjdk-21-jdk maven redis-server mariadb-server \
  python3-venv python3-pip curl unzip ca-certificates

echo "==> [2/6] Configuring Maven mirror (Aliyun public)"
# The project's poms reference a private GitHub Packages repo for the
# agentoz-api artifact; locally we build it from source, so only a public
# mirror is required. Aliyun mirrors everything except that GitHub repo.
mkdir -p "$HOME/.m2"
cat > "$HOME/.m2/settings.xml" <<'XML'
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
          xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
          xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 http://maven.apache.org/xsd/settings-1.0.0.xsd">
  <mirrors>
    <mirror>
      <id>aliyunmaven</id>
      <mirrorOf>*,!github-agentoz</mirrorOf>
      <name>Aliyun Public Repository</name>
      <url>https://maven.aliyun.com/repository/public</url>
    </mirror>
  </mirrors>
</settings>
XML

echo "==> [3/6] Building Java modules (agentoz-api, agentoz-server)"
cd "$REPO_ROOT"
mvn -B clean install -DskipTests

echo "==> [4/6] Setting up Python environment for agentoz-rag"
cd "$REPO_ROOT/agentoz-rag"
if [ ! -d .venv ]; then
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
. .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
deactivate

echo "==> [5/6] Installing Nacos $NACOS_VERSION (config center, discovery, registry)"
if [ ! -x "$NACOS_HOME/bin/startup.sh" ]; then
  curl -fsSL -o /tmp/nacos.tar.gz \
    "https://github.com/alibaba/nacos/releases/download/${NACOS_VERSION}/nacos-server-${NACOS_VERSION}.tar.gz"
  rm -rf "$NACOS_HOME"
  tar -xzf /tmp/nacos.tar.gz -C "$HOME"
  rm -f /tmp/nacos.tar.gz
fi

echo "==> [6/6] Initializing MariaDB data directory"
sudo mkdir -p /run/mysqld /var/run/mysqld
sudo chown mysql:mysql /run/mysqld /var/run/mysqld 2>/dev/null || true
if [ ! -d /var/lib/mysql/mysql ]; then
  sudo mariadb-install-db --user=mysql --datadir=/var/lib/mysql >/dev/null
fi

echo "==> install complete"
