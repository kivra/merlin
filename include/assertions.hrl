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
    ((fun(X__Value) ->
        case X__Value of
            Guard ->
                ok;
            _ ->
                X__GuardSource = merlin_internal:format_merl_guard(?LINE, ??Guard),
                io:format("Expected~n~s~nto match~n~s~n", [
                    merlin_merl:format(X__Value),
                    X__GuardSource
                ]),
                erlang:error(
                    {assertMatch, [
                        {module, ?MODULE},
                        {line, ?LINE},
                        {expression, ??Expr},
                        {pattern, X__GuardSource},
                        {value, merlin:revert(X__Value)}
                    ]}
                )
        end
    end)(Expr))
end).

-define(_assertMerlMatch(Guard, Expr), ?_test(?assertMerlMatch(Guard, Expr))).

%% Merl compatible version of ?assertEqual/2
%% For use with an existing/dynamic `Form', `?assertMerlEqual(Form, Expr)'
%%
%% On failure it pretty prints both the expected and actual syntax trees.
%% It also reverts both the {@link merl:tree/1. expected} and
%% {@link merlin_revert/1. actual} syntax trees to make it easier to compare.
-define(assertMerlEqual(Expected, Expr),
    ((fun(X__Expected, X__Value) ->
        case merl:match(X__Expected, X__Value) of
            {ok, X__Variables} when is_list(X__Variables) ->
                ok;
            error ->
                io:format("Expected~n~s~n~nto equal~n~s~n", [
                    merlin_merl:format(X__Value),
                    merlin_merl:format(X__Expected)
                ]),
                erlang:error(
                    {assertEqual, [
                        {module, ?MODULE},
                        {line, ?LINE},
                        {expression, ??Expr},
                        {expected, merl:tree(X__Expected)},
                        {value, merlin:revert(X__Value)}
                    ]}
                )
        end
    end)(Expected, Expr))
).
-define(_assertMerlEqual(Expected, Expr), ?_test(?assertMerlEqual(Expected, Expr))).

%% Asserts that the given `Expr' is a valid {@link erl_syntax} form.
%%
%% Returns the type of the form.
-define(assertIsForm(Expr), begin
    (fun(X__Node) ->
        try erl_syntax:type(X__Node) of
            __Type__ -> __Type__
        catch
            error:{badarg, X__Node}:__Stacktrace__ ->
                erlang:raise(
                    error,
                    {assertNotException, [
                        {module, ?MODULE},
                        {line, ?LINE},
                        {expression, "erl_syntax:type(" ??Expr ")"},
                        {pattern, "{ error , {badarg, _} , [...] }"},
                        {unexpected_exception, {error, {badarg, X__Node}, __Stacktrace__}}
                    ]},
                    __Stacktrace__
                )
        end
    end)(
        Expr
    )
end).

%% Asserts that the given `Expr' is a valid form with the given `Type'.
-define(assertNodeType(Expr, Type), begin
    (fun
        (X__TypeOfExpr, X__ExpectedType) when X__TypeOfExpr =:= X__ExpectedType ->
            ok;
        (X__TypeOfExpr, X__ExpectedType) ->
            erlang:error(
                {assertEqual, [
                    {module, ?MODULE},
                    {line, ?LINE},
                    {expression, "erl_syntax:type(" ??Expr ") =:= " ??Type},
                    {expected, X__ExpectedType},
                    {value, X__TypeOfExpr}
                ]}
            )
    end)(
        ?assertIsForm(Expr), Type
    )
end).
-endif.
