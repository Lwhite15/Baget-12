#!/bin/bash
# Spins up a throwaway Postgres, applies the stub + migrations + tests. Prints PASS/FAIL.
set -e
BIN=$(ls -d /usr/lib/postgresql/*/bin | head -1)
D=/var/lib/postgresql/bagettest
HERE=$(cd "$(dirname "$0")" && pwd)
su postgres -c "$BIN/pg_ctl -D $D/data stop -m fast >/dev/null 2>&1; rm -rf $D; mkdir -p $D && $BIN/initdb -D $D/data -A trust -U postgres >/dev/null && $BIN/pg_ctl -D $D/data -o '-k $D -p 5498 -c listen_addresses=' -l $D/log start >/dev/null"
sleep 1
cp "$HERE"/supabase_stub.sql "$HERE"/../migrations/*.sql "$HERE"/security_test.sql $D/ && chmod 644 $D/*.sql
P="psql -h $D -p 5498 -U postgres -q -t -v ON_ERROR_STOP=1 -X"
$P -f $D/supabase_stub.sql
for m in $(ls $D/2*.sql | sort); do $P -f "$m" 2>&1 | grep -v "NOTICE:  extension\|does not exist, skipping" || true; done
$P -f $D/security_test.sql 2>&1 | sed -E 's/^psql:[^:]+:[0-9]+: (NOTICE|WARNING):  /\1 /'
su postgres -c "$BIN/pg_ctl -D $D/data stop -m fast >/dev/null; rm -rf $D"
