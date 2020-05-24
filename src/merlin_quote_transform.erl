-module(merlin_quote_transform).

% -behaviour(parse_transform).

-export([parse_transform/2]).

-define(show(AST),
    io:format("~s: ~p~n", [??AST, AST]),
    merl:show([AST])
).

parse_transform(Forms, _Options) ->
    % io:format("qt: ~p~n", [Forms]),
    parse_trans:plain_transform(fun do_transform/1, Forms).

%% Matches `{'MERLIN QUOTE MARKER', ??Forms}' from the `?QQ' macro.
do_transform({tuple, _,
    [ {atom, _, 'MERLIN QUOTE MARKER'}
    , {integer, _, Line }
    , {string, _, Source }]})
->
    % io:format("line: ~p~n", [Line]),
    %% Parse the code inside ?QQ(<code>).
    OriginalAST = merl:quote(Source),
    % ?show(OriginalAST),

    %% Since we ant to return the AST as a literal Erlang term, we need to
    %% lower it one level. The result is an AST with only literal terms:
    %% list (cons), tuple, atom, integer, float and string.
    %% Forntuantely it makes pattern matching easier. Take tuples as an
    %% example, the elements are represented by a list which makes matching
    %% differently sized tuples a breeze.
    ASTofAST = parse_trans:revert_form(erl_syntax:abstract(OriginalAST)),
    % ?show(ASTofAST),

    %% Finally we want to lower variables, so they are bound back in Erlang
    %% land, and ignore all line numbers by replacing them with `_'.
    %% This makes the resulting code usable for pattern matching in function
    %% heads, which is what `parse_trans' needs for its callbacks.
    FinalAST = lift_variables(Line, ASTofAST),
    % ?show(FinalAST),

    FinalAST;
do_transform(_AST) ->
    % io:format("AST: ~p~n", [AST]),
    continue.

lift_variables(Line, {tuple, _,
    [ {atom, _, var }
    , {integer, _Line, _ }
    , {atom, _, VariableName }]})
->
    {var, Line, VariableName};
lift_variables(Line, {tuple, _,
    [ {atom, _,  NodeType}
    , {integer, _, _Line }
    | Tail ]})
->
    % ?show(Tail),
    {tuple, Line,
        [ {atom, Line, NodeType}
        , {var, Line, '_'}
        | [
            lift_variables(Line, Element)
        ||
            Element <- Tail
        ]]};
lift_variables(Line, {cons, _, Head, Tail}) ->
    {cons, Line, lift_variables(Line, Head), lift_variables(Line, Tail)};
lift_variables(_Line, AST) -> AST.