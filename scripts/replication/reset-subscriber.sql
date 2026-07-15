\set ON_ERROR_STOP on

SELECT pg_terminate_backend(pid)
FROM pg_catalog.pg_stat_activity
WHERE datname = :'database_name' AND pid <> pg_backend_pid();
SELECT format('DROP DATABASE IF EXISTS %I WITH (FORCE)', :'database_name')
\gexec
SELECT format('CREATE DATABASE %I OWNER %I', :'database_name', :'database_owner')
\gexec

