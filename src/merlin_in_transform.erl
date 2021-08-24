-module(merlin_in_transform).

-include("merlin_quote.hrl").
-include("log.hrl").

-export([
    parse_transform/2
]).

parse_transform(Forms, _Options) ->
    File = merlin_lib:file(Forms),
    merlin:return(merlin:transform(Forms, fun transformer/3, File)).

transformer(enter, ?QQ("_@Needle and merlin_in_transform:'IN'() and []"), _File) ->
    {error, "empty list for `?in´ comparison"};
transformer(
    enter,
    ?QQ("_@Needle and merlin_in_transform:'IN'() and [_@@Elements]") = Form,
    _File
) ->
    combine(Form, Needle, in, Elements, fun compare/2);
transformer(
    enter,
    ?QQ("_@Needle and merlin_in_transform:'IN'(_@ExpressionAST)") = Form,
    File
) ->
    ExpressionSource = merlin_lib:value(ExpressionAST),
    {ok, Tokens, _} = erl_scan:string(
        ExpressionSource,
        erl_syntax:get_pos(ExpressionAST)
    ),
    {LowTokens, {Kind, _}, HighTokens} = merlin_internal:split_by(
        Tokens,
        fun is_range_op/1
    ),
    case {parse(LowTokens, File), Kind, parse(HighTokens, File)} of
        {{error, LowError}, _, {error, HighError}} ->
            {exceptions, [LowError, HighError], Form, File};
        {{error, LowError}, _, _} ->
            LowError;
        {_, _, {error, HighError}} ->
            HighError;
        {Low, '..', High} ->
            ?QQ("_@Low  < _@Needle andalso _@Needle  < _@High");
        {Low, '...', High} ->
            ?QQ("_@Low =< _@Needle andalso _@Needle =< _@High")
    end;
transformer(
    enter,
    ?QQ("_@Needle =:= merlin_in_transform:'ONE OF'(_@@Args)") = Form,
    _File
) ->
    combine(Form, Needle, oneof, Args, fun '=:='/2);
transformer(
    enter,
    ?QQ("_@Needle == merlin_in_transform:'ONE OF'(_@@Args)") = Form,
    _File
) ->
    combine(Form, Needle, oneof, Args, fun '=='/2);
transformer(_, _, _) ->
    continue.

combine(_Form, _Needle, Macro, [], Fun) when is_function(Fun, 2) ->
    Message = io_lib:format("no elements in `?~s` comparison", [Macro]),
    {error, Message};
combine(Form, Needle, Macro, [Single], Fun) when is_function(Fun, 2) ->
    Message = io_lib:format("only one element for `?~s` comparison", [Macro]),
    {warning, Message, erl_syntax:copy_attrs(Form, Fun(Needle, Single))};
combine(Form, Needle, _Macro, Elements, Fun) when
    length(Elements) > 1 andalso is_function(Fun, 2)
->
    Expressions = [Fun(Needle, Term) || Term <- Elements],
    {Init, Last} = lists:split(length(Expressions) - 1, Expressions),
    erl_syntax:copy_attrs(Form, lists:foldr(fun 'orelse'/2, Last, Init)).

'orelse'(Left, Right) ->
    ?QQ("_@Left orelse _@Right").

'=:='(Left, Right) ->
    erl_syntax:copy_attrs(Left, ?QQ("_@Left =:= _@Right")).

'=='(Left, Right) ->
    erl_syntax:copy_attrs(Left, ?QQ("_@Left == _@Right")).

compare(Needle, Term) ->
    case erl_syntax:type(Term) of
        float -> '=='(Needle, Term);
        _ -> '=:='(Needle, Term)
    end.

is_range_op({'..', _}) -> true;
is_range_op({'...', _}) -> true;
is_range_op(_) -> false.

parse(Tokens, File) ->
    case erl_parse:parse_exprs(Tokens ++ [{dot, 1}]) of
        {error, ErrorInfo} ->
            {error, {File, ErrorInfo}};
        {ok, ExprList} ->
            ExprList
    end.
