\set ON_ERROR_STOP on

SELECT format('CREATE ROLE %I WITH LOGIN REPLICATION PASSWORD %L', :'replication_user', :'replication_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = :'replication_user')
\gexec
SELECT format('ALTER ROLE %I WITH LOGIN REPLICATION PASSWORD %L', :'replication_user', :'replication_password')
\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'database_name', :'replication_user')
\gexec
SELECT format('GRANT USAGE ON SCHEMA public TO %I', :'replication_user')
\gexec
SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA public TO %I', :'replication_user')
\gexec
SELECT format(
    'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public GRANT SELECT ON TABLES TO %I',
    :'application_user',
    :'replication_user'
)
\gexec

SELECT pg_drop_replication_slot(slot_name)
FROM pg_catalog.pg_replication_slots
WHERE slot_name = :'subscription_name' AND NOT active;

SELECT format('DROP PUBLICATION IF EXISTS %I', :'publication_name')
\gexec
SELECT format('CREATE PUBLICATION %I FOR TABLES IN SCHEMA public WITH (publish_via_partition_root = true)', :'publication_name')
\gexec
