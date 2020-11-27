-module(merlin_in_transform).

-include("merlin.hrl").
-include("log.hrl").

-export([
    parse_transform/2
]).

parse_transform(Forms, _Options) ->
    File = merlin_lib:file(Forms),
    merlin:return(merlin:transform(Forms, fun transformer/3, File)).

transformer(enter, ?QQ("_@Needle and merlin_in_transform:'IN'() and []"), File) ->
    {error, "empty list for `?in´ comparison"};
transformer(enter, ?QQ("_@Needle and merlin_in_transform:'IN'() and [_@Single]"), File) ->
    {warning, "only one element in `?in` comparison", compare(Needle, Single)};
transformer(enter, ?QQ("_@Needle and merlin_in_transform:'IN'() and [_@@Elements]"), File) ->
    [First|Rest] = [compare(Needle, Term) || Term <- Elements],
    erl_syntax:copy_pos(__NODE__, lists:foldl(fun join/2, First, Rest));
transformer(enter, ?QQ("_@Needle and merlin_in_transform:'IN'(_@ExpressionAST)"), File) ->
    ExpressionSource = merlin_lib:value(ExpressionAST),
    {ok, Tokens, _} = erl_scan:string(
        ExpressionSource, erl_syntax:get_pos(ExpressionAST)
    ),
    {LowTokens, {Kind, _}, HighTokens} = merlin_lib:split_by(
        Tokens, fun is_range_op/1
    ),
    case {parse(LowTokens, File), Kind, parse(HighTokens, File)} of
        {{error, LowError}, _, {error, HighError}} ->
            {exceptions, [LowError, HighError], __NODE__, File};
        {{error, LowError}, _, _} ->
            LowError;
        {_, _, {error, HighError}} ->
            HighError;
        {Low, '..', High} ->
            ?QQ("_@Low  < _@Needle andalso _@Needle  < _@High");
        {Low, '...', High} ->
            ?QQ("_@Low =< _@Needle andalso _@Needle =< _@High")
    end;
transformer(_, _, _) ->
    continue.

join(Left, Right) ->
    ?QQ("_@Left orelse _@Right").

compare(Needle, Term) ->
    case erl_syntax:type(Term) of
        float -> ?QQ("_@Needle == _@Term");
        _     -> ?QQ("_@Needle =:= _@Term")
    end.

is_range_op({'..',  _}) -> true;
is_range_op({'...', _}) -> true;
is_range_op(_)          -> false.

parse(Tokens, File) ->
    case erl_parse:parse_exprs(Tokens ++ [{dot, 1}]) of
        {error, ErrorInfo} ->
            {error, {File, ErrorInfo}};
        {ok, ExprList} ->
            ExprList
    end.