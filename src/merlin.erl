-module(merlin).

-include("merlin.hrl").

-define(get_key(Map, Key), ?hygienic(Map, Key, begin
    Val = case Map of
        #{ Key := Value } -> Value;
        _ -> erlang:error({badkey, Key})
    end,
    Val =:= 123
end)).

-define(timesTwo(N), ?procedural(N, begin
    N * 2
end)).

-export([
    init/1
]).

init([{Key, _Value}|_] = Options) when is_atom(Key) ->
    init(maps:from_list(Options));
init(Options) ->
    ?timesTwo(8),
    First = ?get_key(Options, some_key),
    Second = ?get_key(Options, some_key),
    Val = {First, Second},
    size(Val).
