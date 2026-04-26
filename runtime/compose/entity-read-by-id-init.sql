-- Initialize pg_stat_statements extension and grant permissions to benchmark user
-- Executed on first cluster initialization by docker-entrypoint-initdb.d
-- Target: PostgreSQL 15+ / 16.x
-- In PG 15+, pg_stat_statements_reset() identity is: pg_stat_statements_reset(userid Oid, dbid Oid, queryid bigint)
-- The zero-argument form does not have a separate catalog identity; GRANT must target the 3-arg form.

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Read access to extension views
GRANT SELECT ON pg_stat_statements TO benchmark;
GRANT SELECT ON pg_stat_statements_info TO benchmark;

-- PG 15+ / PG 16 function identity: third argument is bigint (NOT Oid)
GRANT EXECUTE ON FUNCTION pg_stat_statements_reset(Oid, Oid, bigint) TO benchmark;

-- Init confirmation (valid SQL, no cast)
SELECT format('pg_stat_statements extension initialized; grants applied by user: %s', current_user);
