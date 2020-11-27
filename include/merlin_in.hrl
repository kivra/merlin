-ifndef(MERLIN_IN).
-define(MERLIN_IN, true).

-compile({parse_transform, merlin_in_transform}).

-define(in, and merlin_in_transform:'IN'() and).

-define(in(Expression), and merlin_in_transform:'IN'(??Expression)).

-define(in(High, Low), in(High .. Low)).

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
            {error, "empty list for `?in´ comparison"};
        [Single] ->
            {warning, "only one element in `?in` comparison", Compare(Single)};
        _ ->
            [First|Rest] = lists:map(Compare, Elements),
            erl_syntax:copy_pos(Needle, lists:foldl(
                fun(Left, Right) -> ?QQ("_@Left orelse _@Right") end,
                First,
                Rest
            ))
    end
end)).

-endif.