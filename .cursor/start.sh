#!/usr/bin/env bash
# AgentOZ Cloud Agent start: per-boot reconciliation of local infrastructure
# (MariaDB, Redis, Nacos). Idempotent: detects already-running services,
# waits for readiness, then returns. Application servers are launched
# separately (RAG in a terminal; the Java server is run on demand).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}"
NACOS_HOME="$HOME/nacos"

wait_for() { # name host port timeout_s
  local name="$1" host="$2" port="$3" timeout="${4:-60}" i=0
  until (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; do
    i=$((i+1)); [ "$i" -ge "$timeout" ] && { echo "!! $name not ready on $host:$port"; return 1; }
    sleep 1
  done
  echo "-- $name ready on $host:$port"
}

echo "==> Starting Redis"
if ! redis-cli ping >/dev/null 2>&1; then
  sudo mkdir -p /var/lib/redis
  sudo redis-server --daemonize yes --dir /var/lib/redis
fi
wait_for redis 127.0.0.1 6379

echo "==> Starting MariaDB"
if ! mysqladmin --protocol=tcp -h 127.0.0.1 -uroot ping >/dev/null 2>&1; then
  # mariadbd binds its unix socket at /run/mysqld/mysqld.sock. Create both
  # /run/mysqld and /var/run/mysqld so it works whether or not /var/run is a
  # symlink to /run on the host image.
  sudo mkdir -p /run/mysqld /var/run/mysqld
  sudo chown mysql:mysql /run/mysqld /var/run/mysqld 2>/dev/null || true
  sudo mariadbd --user=mysql --datadir=/var/lib/mysql >/tmp/mariadb.log 2>&1 &
fi
wait_for mariadb 127.0.0.1 3306
# Ensure root is reachable over TCP with an empty password (dev default).
sudo mariadb -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING ''; FLUSH PRIVILEGES;" 2>/dev/null || true

echo "==> Loading database schema (only when missing)"
# init.sql seeds rows with fixed primary keys, so it is not safe to re-run.
# Load it only when the schema has not been created yet.
table_exists() {
  mysql -h 127.0.0.1 -uroot -N -B -e \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='agentoz' AND table_name='$1'" 2>/dev/null
}
if [ "$(table_exists agent)" != "1" ]; then
  mysql -h 127.0.0.1 -uroot < "$REPO_ROOT/sql/init.sql"
  echo "-- loaded init.sql"
fi
if [ "$(table_exists async_tasks)" != "1" ]; then
  mysql -h 127.0.0.1 -uroot agentoz < "$REPO_ROOT/sql/create_async_tasks_table.sql"
  echo "-- loaded create_async_tasks_table.sql"
fi

echo "==> Starting Nacos (standalone)"
if ! (exec 3<>/dev/tcp/127.0.0.1/8848) 2>/dev/null; then
  ( cd "$NACOS_HOME/bin" && bash startup.sh -m standalone >/dev/null 2>&1 )
fi
wait_for nacos 127.0.0.1 8848 90

echo "==> Infrastructure ready: Redis:6379  MariaDB:3306  Nacos:8848"
