-module(macros_example).

-compile([export_all, nowarn_export_all]).

-include("merlin_quote.hrl").
-include("merlin_macros.hrl").

simple_eval() ->
    GoldenRatio = ?eval(begin
        Fibonacci =
            fun Fibonacci(0) -> 0;
                Fibonacci(1) -> 1;
                Fibonacci(N) -> Fibonacci(N - 1) + Fibonacci(N - 2)
            end,
        Fibonacci(12) / Fibonacci(11)
    end),
    GoldenRatio.

%% Similar to the merlin_in operator, but implemented using a procedural macro.
-define(oneof(Needle_, Elements_), ?procedural(oneof(Needle, Elements), begin
    [Needle] = abstract(Needle_),
    Elements = Elements_,
    Compare =
        fun(Term) when is_float(Term) ->
                ?QQ("_@Needle == _@Term@");
           (Term) ->
                ?QQ("_@Needle =:= _@Term@")
        end,
    case Elements of
        [] ->
            {error, "empty list for `?oneof´ comparison"};
        [Single] ->
            {warning, "only one element in `?oneof` comparison", Compare(Single)};
        _ ->
            [First|Rest] = lists:map(Compare, Elements),
            erl_syntax:copy_pos(Needle, lists:foldl(
                fun(Left, Right) -> ?QQ("_@Left orelse _@Right") end,
                First,
                Rest
            ))
    end
end)).

simple_procedural(MaybeFamous) when is_integer(MaybeFamous) orelse is_float(MaybeFamous) ->
    ?oneof(MaybeFamous, [0, 1.618, 2.718, 3.14]).

%% Alternative implementation of stdlib assert, without tricks like
%% <abbr title="Immediately Invoked Function Expression">IIFE</abbr>.
-define(expect(Expected, Guard), ?hygienic(expect(Expected, Guard), begin
    case (Expected) of
        Guard -> ok;
        Value ->
            erlang:error(
                {assertMatch,
                [{module, ?MODULE},
                {line, ?LINE},
                {expression, (??Expected)},
                {pattern, (??Guard)},
                {value, Value}]}
            )
    end
end)).

%% Even though we call ?expect twice, and it doesn't introduce a new binding
%% scope, this still compiles and runs just fine.
%% A traditional macro fails with a "unsafe use of Value", and even if it
%% would compile it would match on previous Value/Guard expressions.
simple_hygienic() ->
    ?expect(123, N when is_integer(N)),
    ?expect("hello", "hell" ++ _).

-define(l(Expr), begin (fun(Value) ->
    io:format("~s =~n~tp~n", [??Expr, Value]),
    Value
end)(Expr) end).

-include("log.hrl").

-define(def(NAME, BODY), ?module_procedural(def(NAME, BODY), begin
    Name = abstract(NAME),
    [Fun] = abstract(BODY),
    ?QQ("fun(_@_) -> _@_@Clauses end") = Fun,
    Arity = erl_syntax:fun_expr_arity(Fun),
    Pos = ?LINE,
    Integer = {type, Pos, integer, []},
    Args = lists:duplicate(Arity, Integer),
    Return = Integer,
    Spec = {
        attribute, Pos, spec, {{NAME, Arity}, [
            {type, Pos, 'fun', [{type, Pos, product, Args}, Return]}
        ]}
    },
    [
        Spec,
        ?QQ("'@Name'() -> _@_@Clauses.")
    ]
end)).

?def(module_level, fun (A, B) ->
    A + B
end).