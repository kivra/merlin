-include_lib("stdlib/include/assert.hrl").

-ifdef(NOASSERT).
-define(assertMerlMatch(Guard, Expr), ok).
-define(assertMerlEqual(Expected, Expr), ok).
-define(assertIsForm(Expr), ok).
-define(assertNodeType(Expr, Type), ok).
-else.
%% Merl compatible version of ?assertEqual/2
%% For use with merls `?Q/1' macro, `?assertMerlMatch(?Q(...) when ..., Expr)'
%%
%% On failure it pretty prints both the guard and matched value.
%% It also reverts both the {@link merl:tree/1. expected} and
%% {@link merlin_revert/1. actual} syntax trees to make it easier to compare.
-define(assertMerlMatch(Guard, Expr), begin
    ((fun() ->
        __Value__ = Expr,
        case __Value__ of
            Guard ->
                ok;
            _ ->
                __GuardSource__ = merlin_internal:format_merl_guard(?LINE, ??Guard),
                io:format("Expected~n~s~nto match~n~s~n", [
                    merlin_merl:format(__Value__),
                    __GuardSource__
                ]),
                erlang:error(
                    {assertMatch, [
                        {module, ?MODULE},
                        {line, ?LINE},
                        {expression, ??Expr},
                        {pattern, __GuardSource__},
                        {value, merlin:revert(__Value__)}
                    ]}
                )
        end
    end)())
end).

%% Merl compatible version of ?assertEqual/2
%% For use with merls `?Q/1' macro, `?assertMerlEqual(?Q(...), Expr)'
%%
%% On failure it pretty prints both the expected and actual syntax trees.
%% It also reverts both the {@link merl:tree/1. expected} and
%% {@link merlin_revert/1. actual} syntax trees to make it easier to compare.
-define(assertMerlEqual(Expected, Expr),
    ((fun() ->
        __Value__ = Expr,
        case __Value__ of
            Expected ->
                ok;
            _ ->
                io:format("Expected~n~s~n~nto equal~n~s~n", [
                    merlin_merl:format(__Value__),
                    merlin_merl:format(Expected)
                ]),
                erlang:error(
                    {assertEqual, [
                        {module, ?MODULE},
                        {line, ?LINE},
                        {expression, ??Expr},
                        {expected, merl:tree(Expected)},
                        {value, merlin:revert(__Value__)}
                    ]}
                )
        end
    end)())
).

%% Asserts that the given `Expr' is a valid {@link erl_syntax} form.
%%
%% Returns the type of the form.
-define(assertIsForm(Expr), begin
    ((fun() ->
        Node__ = Expr,
        try erl_syntax:type(Node__) of
            __Type__ -> __Type__
        catch
            error:{badarg, Node__}:__Stacktrace__ ->
                erlang:raise(
                    error,
                    {assert,
                        [
                            {module, ?MODULE},
                            {line, ?LINE},
                            {expression, "erl_syntax:type(" ??Expr ")"},
                            {expected, true},
                            {value, false}
                        ]
                    },
                    __Stacktrace__
                )
        end
    end))()
end).

%% Asserts that the given `Expr' is a valid form with the given `Type'.
-define(assertNodeType(Expr, Type), begin
    ((fun() ->
        Type__ = Type,
        case ?assertIsForm(Expr) of
            Type__ -> ok;
            __Value__ ->
                erlang:error(
                    {assertEqual,
                        [
                            {module, ?MODULE},
                            {line, ?LINE},
                            {expression, "erl_syntax:type(" ??Expr ") =:= " ??Type},
                            {expected, Type__},
                            {value, __Value__}
                        ]
                    }
                )
        end
    end))()
end).
-endif.