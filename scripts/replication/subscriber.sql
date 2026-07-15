\set ON_ERROR_STOP on

SELECT format('DROP SUBSCRIPTION IF EXISTS %I', :'subscription_name')
\gexec
SELECT format(
    'CREATE SUBSCRIPTION %I CONNECTION %L PUBLICATION %I WITH (copy_data = false, create_slot = true, enabled = true)',
    :'subscription_name', :'subscription_connection', :'publication_name'
)
\gexec

