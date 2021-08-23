-module(in_example).

-compile([export_all, nowarn_export_all]).

-include("merlin_in.hrl").

simple(MaybeGreeting) when MaybeGreeting ?in [hello, "hello", <<"hello">>] ->
    ok.

range(Map, N) when N ?in(map_get(key, Map) .. 10) ->
    ok.
