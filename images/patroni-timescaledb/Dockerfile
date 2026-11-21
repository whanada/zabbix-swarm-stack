ARG TIMESCALE_BASE=timescale/timescaledb:2.29.0-pg17
ARG ZABBIX_SCHEMA_IMAGE=zabbix/zabbix-server-pgsql:ubuntu-8.0.0
FROM ${ZABBIX_SCHEMA_IMAGE} AS zabbix_schema
FROM ${TIMESCALE_BASE}

ARG PATRONI_VERSION=4.1.5
COPY --from=zabbix_schema /usr/share/doc/zabbix-server-postgresql/postgresql/ /opt/zabbix-schema/
COPY --from=zabbix_schema /usr/share/doc/zabbix-server-postgresql/clickhouse/ /opt/zabbix-clickhouse/
USER root
RUN apk add --no-cache py3-pip bash curl && \
    python3 -m venv /opt/patroni && \
    /opt/patroni/bin/pip install --no-cache-dir "patroni[etcd3,psycopg3]==${PATRONI_VERSION}" && \
    /opt/patroni/bin/pip check
ENV PATH="/opt/patroni/bin:${PATH}"
USER postgres
ENTRYPOINT ["/opt/patroni/bin/patroni"]
CMD ["/etc/patroni/patroni.yml"]
