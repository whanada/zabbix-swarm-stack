#!/usr/bin/env python3
"""Render and validate the proposed AWS stacks without deploying them."""
import json
import subprocess
import tempfile
from pathlib import Path
from xml.etree import ElementTree

import yaml
from jinja2 import Environment, FileSystemLoader, StrictUndefined

ROOT = Path(__file__).resolve().parent.parent
env = Environment(loader=FileSystemLoader(ROOT / "ansible/aws/templates"), undefined=StrictUndefined)
env.filters["to_json"] = json.dumps
server_vars = yaml.safe_load((ROOT / "ansible/aws/vars/server.yml").read_text())["zabbix_server_environment"]
required_keys = {line for line in (ROOT / "tests/fixtures/legacy-server-environment.txt").read_text().splitlines() if line and not line.startswith("#")}
missing = required_keys - set(server_vars)
if missing:
    raise SystemExit(f"Required server environment variables missing: {sorted(missing)}")

common = dict(
    etcd_image="quay.io/coreos/etcd:v3.5.21",
    patroni_image="753226848084.dkr.ecr.us-east-1.amazonaws.com/whanada/zabbix-ha-stack:2.29.0-pg17-patroni4.1.5-r2-zabbix8.0.0",
    haproxy_image="haproxy:3.0.11-alpine",
    pgbouncer_image="edoburu/pgbouncer:v1.25.2-p0",
    postgres_exporter_image="prometheuscommunity/postgres-exporter:v0.20.1",
    pgbouncer_exporter_image="prometheuscommunity/pgbouncer-exporter:v0.12.1",
    pgscv_image="cherts/pgscv:v0.15.3",
    pgscv_config_name="config_pgscv",
    process_exporter_config_name="config_process",
    node_exporter_image="prom/node-exporter:v1.12.1",
    process_exporter_image="ncabatoff/process-exporter:0.8.7",
    cadvisor_image="ghcr.io/google/cadvisor:v0.60.6",
    patroni_config_name="config_patroni",
    haproxy_config_name="config_haproxy",
    pgbouncer_haproxy_config_name="config_pgbouncer_haproxy",
    clickhouse_server_image="clickhouse/clickhouse-server:26.8.40.7",
    clickhouse_keeper_image="clickhouse/clickhouse-keeper:26.8.40.7",
    keeper_config_names={str(n): f"keeper_{n}" for n in range(1, 4)},
    clickhouse_config_names={str(n): f"clickhouse_{n}" for n in range(1, 4)},
    clickhouse_haproxy_config_name="clickhouse_haproxy",
    traefik_image="traefik:v3.7.7",
    zabbix_server_image="zabbix/zabbix-server-pgsql:ubuntu-8.0.0",
    zabbix_web_image="zabbix/zabbix-web-nginx-pgsql:ubuntu-8.0.0",
    zabbix_webservice_image="zabbix/zabbix-web-service:ubuntu-8.0.0",
    zabbix_proxy_image="zabbix/zabbix-proxy-sqlite3:ubuntu-8.0.0",
    selenium_image="selenium/standalone-chrome:4.44.0-20260505",
    zabbix_standby_replicas=0,
    zabbix_proxy_hostname="proxy001",
    zabbix_apm_enabled=True,
    traefik_dynamic_name="traefik_config",
    zabbix_server_environment=server_vars,
    zabbix_tcp_hostname="zabbix-tcp.example.org",
    zabbix_web_hostname="zabbix.example.org",
)
for n in range(1, 4):
    for name in ("clickhouse-server.xml.j2", "clickhouse-keeper.xml.j2"):
        ElementTree.fromstring(env.get_template(name).render(clickhouse_node=n))

traefik = yaml.safe_load(env.get_template("traefik-dynamic.yml.j2").render(**common))
addresses = traefik["tcp"]["services"]["zabbix-server"]["loadBalancer"]["servers"]
assert [server["address"].split(":")[-1] for server in addresses] == ["10051", "10052", "10053"]

for name in ("data-stack.yml.j2", "clickhouse-stack.yml.j2", "app-stack.yml.j2", "metrics-stack.yml.j2"):
    rendered = env.get_template(name).render(**common)
    with tempfile.NamedTemporaryFile(mode="w", suffix=".yml") as output:
        output.write(rendered)
        output.flush()
        subprocess.run(["docker", "stack", "config", "-c", output.name], check=True, stdout=subprocess.DEVNULL)
    print(f"{name}: configuration valid")
