# Zabbix 8 AWS deployment: design and outstanding work

The AWS deployment is under development and is not yet complete or production-ready.

## Topology

Six EC2 instances: three Swarm managers and three workers in separate availability zones. Each worker hosts one Patroni instance, one etcd member, one ClickHouse instance and one Keeper member; worker 3 hosts proxy 001. Three Zabbix HA servers are placed on different workers.

Every Swarm overlay network attached to Traefik must be created with Docker's
`--opt encrypted` option. Validate the network driver and encryption option
before attaching Traefik or application services, and fail rather than reuse an
unencrypted network. Overlay encryption protects traffic between Swarm nodes;
it does not replace application TLS or protect traffic outside the overlay.

Each stateful instance needs its own dedicated virtual disk and persistent
filesystem. Disk identities must be checked before formatting. Swarm local
volumes are node-local: placement constraints must prevent the workload from
starting against an empty volume on another node. Define separate backup and
restore procedures; replication is not a backup.

## Data and traffic

Patroni requires three independent, persistent etcd members and PostgreSQL
physical replication. HAProxy must check the Patroni primary endpoint so writes
reach only the leader; provision HAProxy redundantly and specify how clients
reach it when a node fails. Initialize the Zabbix schema once, enable the
matching TimescaleDB schema once, and start the second Zabbix node only after
bootstrap completes. Test loss of a database leader and subsequent recovery.

Zabbix native HA has a single active server. TCP routing must select the active
server rather than blindly round-robin between active and standby. Verify the
health check against real 8.0 images and failover behavior. Traefik HostSNI
rules require TLS clients that actually send matching SNI; plain TCP and TLS
clients without SNI need a separately designed route. Test each supported agent
and proxy connection mode before enabling it.

For APM, provision a supported ClickHouse telemetry data source and
an APM-capable Zabbix 8 proxy. Configure the proxy's APM collector and the
Zabbix data source. Standard monitoring remains usable without APM. Validate
the OpenTelemetry ingestion path end to end, including the database schema,
network, authentication, and retention policy.

## Version and operations gates

Select and pin real, published component image tags and verify compatibility
before building. Zabbix 8.0 requires PostgreSQL 15–18 and TimescaleDB 2.20–2.31
as documented at the time of writing; TimescaleDB 2.30 and 2.31 require Zabbix
8.0.1 or newer. APM's ClickHouse version has a separate minimum. Some products
do not offer an LTS release channel, so a blanket requirement that every image
use an LTS tag needs an explicit exception policy rather than an invented tag.

On 2026-11-21 the official `zabbix/zabbix-server-pgsql:ubuntu-8.0.1`
manifest was not found. For a test using the released `ubuntu-8.0.0`, use a
supported 2.20–2.29 TimescaleDB release. Once 8.0.1 images are actually
published, recheck the requirements and image tags, then test the upgrade to
TimescaleDB 2.31 before adopting it. Do not silently bypass the Zabbix version
check to use an unsupported extension.

Create Swarm secrets without logging their values, and create the requested
`.secrets-temp.txt` with mode 0600, outside version control. The file contains
sensitive credentials and needs a defined rotation and secure disposal policy.
Make reruns idempotent; Swarm secrets and configs are immutable and need
versioned names or explicit rotation.

Required validation includes a non-mutating preflight, Ansible syntax and check
mode where supported, template rendering, real Swarm deployment, PostgreSQL
leader failure, etcd quorum, Zabbix HA failover, TLS routing, and an
OTLP test. Check mode cannot prove instance creation or service convergence.

References: [Zabbix 8 requirements](https://www.zabbix.com/documentation/8.0/en/manual/installation/requirements),
[Zabbix native HA](https://www.zabbix.com/documentation/8.0/en/manual/concepts/server/ha),
[Zabbix APM](https://www.zabbix.com/documentation/8.0/en/manual/web_interface/frontend_sections/apm),
[Traefik TCP routing](https://doc.traefik.io/traefik/reference/routing-configuration/tcp/routing/rules-and-priority/).
