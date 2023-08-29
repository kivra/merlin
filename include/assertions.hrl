-ifndef(MERLIN_ASSERTIONS_HRL).
-define(MERLIN_ASSERTIONS_HRL, true).

-include_lib("stdlib/include/assert.hrl").

-ifdef(NOASSERT).
-define(if_asserting(Block), ok).
-define(assertMerlMatch(Guard, Expr), ok).
-define(assertMerlEqual(Expected, Expr), ok).
-define(assertIsNode(Expr), ok).
-define(assertNodeType(Expr, Type), ok).
-define(assertRegexpMatch(Regexp, Subject), ok).
-else.
%% Helper for compiling away code when assertions are disabled
-define(if_asserting(Block), Block).

%% Merl compatible version of ?assertEqual/2
%%
%% For use with {@link merl. merls} `?Q/1' macro,
%% `?assertMerlMatch(?Q(...) when ..., Expr)'
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
                merlin_internal:print_merl_match_failure(??Guard, X__Value, #{
                    filename => ?FILE
                }),
                erlang:error(
                    {assertMatch, [
                        {module, ?MODULE},
                        {line, ?LINE},
                        {expression, ??Expr},
                        {pattern, ??Guard},
                        {value, merlin:revert(X__Value)}
                    ]}
                )
        end
    end)(
        Expr
    ))
end).

-define(_assertMerlMatch(Guard, Expr), ?_test(?assertMerlMatch(Guard, Expr))).

%% Merl compatible version of ?assertEqual/2
%%
%% For use with an existing/dynamic `Node', `?assertMerlEqual(Node, Expr)'
%%
%% On failure it pretty prints the diff between the expected and actual syntax
%% trees.
%%
%% It also reverts both the {@link merl:tree/1. expected} and
%% {@link merlin_revert/1. actual} syntax trees to make them easier to
%% inspect and compare.
-define(assertMerlEqual(Expected, Expr),
    ((fun(X__Expected, X__Value) ->
        case merl:match(X__Expected, X__Value) of
            {ok, X__Variables} when is_list(X__Variables) ->
                ok;
            error ->
                merlin_internal:print_merl_equal_failure(X__Expected, X__Value, #{
                    filename => ?FILE
                }),
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
    end)(
        Expected, Expr
    ))
).
-define(_assertMerlEqual(Expected, Expr), ?_test(?assertMerlEqual(Expected, Expr))).

%% Asserts that the given `Expr' is a valid {@link erl_syntax} node.
%%
%% Returns the type of the node.
-define(assertIsNode(Expr), begin
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
                        {unexpected_exception,
                            {error, {badarg, X__Node}, __Stacktrace__}}
                    ]},
                    __Stacktrace__
                )
        end
    end)(
        Expr
    )
end).

%% Asserts that the given `Expr' is a valid node with the given `Type'.
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
        ?assertIsNode(Expr), Type
    )
end).

-define(assertRegexpMatch(Regexp, Subject), begin
    (fun(X__Subject, X__Regexp) ->
        case re:run(X__Subject, X__Regexp, [{capture, none}]) of
            match ->
                ok;
            nomatch ->
                error(assertMatch, [
                    {module, ?MODULE},
                    {line, ?LINE},
                    {expression,
                        unicode:characters_to_list(
                            io_lib:format("re:run(~s, ~tp, [{capture, none}])", [
                                ??Subject, X__Regexp
                            ])
                        )},
                    {pattern, "{match, _}"},
                    {value, X__Subject}
                ])
        end
    end)(
        Subject, Regexp
    )
end).

-endif.
-endif.
