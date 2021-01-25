.PHONY : clean compile E P examples dialyzer
REBAR3_PLT := _build/default/rebar3_$(shell asdf current erlang | tr -s ' ' | cut -d' ' -f2)_plt
EBINS := $(wildcard _build/default/lib/*/ebin)

all: E P examples

clean:
	rm -f typer_results.erl _build/*/lib/*/{ebin,examples}/*.{E,P}
	rebar3 clean

compile: _build/default/lib/merlin/ebin/merlin.beam

P: _build/P/lib/merlin/ebin/merlin.beam

E: _build/E/lib/merlin/ebin/merlin.beam

examples: _build/examples/lib/merlin/ebin/merlin.beam examples/*

dialyzer: ${REBAR3_PLT}

${REBAR3_PLT}: src/* include/*
	rebar3 dialyzer

typer_results.erl: ${REBAR3_PLT}
	asdf env erl typer $(EBINS:%=-pa %) --plt $@ -I include/ -r src > typer_results.erl

_build/default/lib/merlin/ebin/merlin.beam console.log: src/* include/* priv/*
	env ERL_AFLAGS="-config priv/sys.config" \
	rebar3 compile

_build/%/lib/merlin/ebin/merlin.beam: _build/default/lib/merlin/ebin/merlin.beam
	# env ERL_AFLAGS="-kernel logger_level warning"
	env ERL_AFLAGS="-config priv/sys.config" \
	rebar3 as $* compile