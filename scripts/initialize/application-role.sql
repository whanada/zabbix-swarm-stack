\set ON_ERROR_STOP on

SELECT format('CREATE ROLE %I WITH LOGIN PASSWORD %L', :'application_user', :'application_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = :'application_user')
\gexec
SELECT format('ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD %L', :'application_user', :'application_password')
\gexec
SELECT format('ALTER DATABASE %I OWNER TO %I', :'database_name', :'application_user')
\gexec
SELECT format('ALTER SCHEMA public OWNER TO %I', :'application_user')
\gexec
SELECT format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO %I', :'database_name', :'application_user')
\gexec
SELECT format('GRANT USAGE, CREATE ON SCHEMA public TO %I', :'application_user')
\gexec

