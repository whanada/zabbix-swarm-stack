#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${PATRONI_IMAGE:?Load .env before testing}"
db=zbx-pgb-db-$$
pool=zbx-pgb-pool-$$
exp=zbx-pgb-exporter-$$
cleanup() { docker rm -f "$exp" "$pool" "$db" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
cleanup
docker run -d --name "$db" --network none --entrypoint /bin/sh "$PATRONI_IMAGE" -ec 'initdb -D /tmp/pgdata -U postgres --no-instructions >/dev/null; exec postgres -D /tmp/pgdata -c listen_addresses=127.0.0.1' >/dev/null
for i in $(seq 1 30); do docker exec "$db" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 && break; sleep 1; done
docker exec "$db" psql -h 127.0.0.1 -U postgres -c "CREATE ROLE zabbix LOGIN PASSWORD 'testpass';" >/dev/null
docker exec "$db" psql -h 127.0.0.1 -U postgres -c 'CREATE DATABASE zabbix OWNER zabbix;' >/dev/null
docker run -d --name "$pool" --network "container:$db" -e DB_USER=zabbix -e DB_PASSWORD=testpass -e DB_HOST=127.0.0.1 -e DB_NAME=zabbix -e LISTEN_PORT=15432 -e AUTH_TYPE=scram-sha-256 -e STATS_USERS=zbx_stats --entrypoint /bin/sh "${PGBOUNCER_IMAGE:?Load .env before testing}" -ec 'printf "\"zbx_stats\" \"statssecret\"\n" > /etc/pgbouncer/userlist.txt; exec /entrypoint.sh /usr/bin/pgbouncer /etc/pgbouncer/pgbouncer.ini' >/dev/null
docker run -d --name "$exp" --network "container:$db" "${PGBOUNCER_EXPORTER_IMAGE:?Load .env before testing}" '--pgBouncer.connectionString=host=127.0.0.1 port=15432 dbname=pgbouncer sslmode=disable user=zbx_stats password=statssecret' >/dev/null
for i in $(seq 1 30); do
 if docker exec "$db" wget -qO /tmp/pgb-metrics http://127.0.0.1:9127/metrics 2>/dev/null && docker exec "$db" grep -q '^pgbouncer_up 1' /tmp/pgb-metrics; then echo 'PgBouncer exporter authenticated and reported pgbouncer_up=1'; exit 0; fi
 sleep 1
done
docker logs "$exp" 2>&1 | tail -20
exit 1
