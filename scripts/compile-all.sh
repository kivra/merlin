#!/bin/sh

export ERL_AFLAGS="-config priv/sys.config"

set -o pipefail -e

rebar3 clean
echo > console.log

if ! rebar3 compile | xargs -L1 -P1 -I@ -- printf "\r\033[K%s\r" @; then
    cat console.log
    exit 1
fi

export ERL_AFLAGS="-kernel logger_level warning"

for T in E P; do
    rebar3 as $T compile | xargs -L1 -P1 -I@ -- printf "\r\033[K%s\r" @
done

erlc -E -v -I include/ -o ebin -pa _build/default/lib/merlin/ebin/ examples/with_statement_example.erl