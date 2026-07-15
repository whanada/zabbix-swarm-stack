\set ON_ERROR_STOP on
SELECT format('DROP SUBSCRIPTION IF EXISTS %I', :'subscription_name')
\gexec

