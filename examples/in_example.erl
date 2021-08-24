-module(in_example).

-compile([export_all, nowarn_export_all]).

-include("merlin_in.hrl").

simple(MaybeGreeting) when MaybeGreeting ?in [hello, "hello", <<"hello">>] ->
    ok.

range(Map, N) when N ?in(map_get(key, Map) .. 10) ->
    ok.

one_of(N, M) when N =:= ?oneof(1, 2, 3) andalso M == ?oneof(3.14, 2.7) ->
    ok.
