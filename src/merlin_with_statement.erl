-module(merlin_with_statement).

-include("merlin_quote.hrl").
-include("log.hrl").

-export([ parse_transform/2 ]).

parse_transform({error, _Errors, _Warnings} = Result, _Options) ->
    Result;
parse_transform({warning, _Tree, _Warnings} = Result, _Options) ->
    Result;
parse_transform(Forms, Options) ->
    AnnotatedForms = merlin:annotate(Forms, [file]),
    {FinalForms, _FinalState} = merlin:transform(
        AnnotatedForms, fun transform_with_statement/3, #{
            options => Options
            % module => merlin_lib:module(Forms),
            % file => merlin_lib:file(Forms)
        }
    ),
    merlin:return(FinalForms).

transform_with_statement(
    enter,
    ?QQ([ "'@Name'(_@Args) when _@__@Guard -> _@_@Body." ]) = Form,
    State
) ->
    {continue, Form, State#{
        bindings => erl_syntax_lib:variables(Form)
    }};
transform_with_statement(
    enter,
    ?QQ([ "case merlin_with_statement:'MARKER'() and ["
        , "    _"
        , "||"
        , "    _@@Expressions"
        , "] of"
        , "    _@_ -> _@_@Clauses"
        , "end"]),
    State
) ->
    {SuccessCases, ErrorCases} = partition_cases(Clauses),
    with_statement(
        State,
        success_case_type(SuccessCases),
        error_case_type(ErrorCases),
        Expressions,
        SuccessCases,
        ErrorCases
    );
transform_with_statement(
    enter,
    ?QQ([ "case merlin_with_statement:'MARKER'() and ["
        , "    _@Head"
        , "||"
        , "    _@@_"
        , "] of"
        , "    _@_ -> _@__"
        , "end"]) = Form,
    _State
) ->
    merlin_lib:into_error_marker(
        "list comprehension head must be _, the anonymous variable",
        merlin_lib:set_annotation(
            Head, file, merlin_lib:get_annotation(Form, file)
        )
    );
transform_with_statement(_, _, _) -> continue.

partition_cases(Cases) ->
    partition_cases(Cases, []).

partition_cases([], SuccessCases) ->
    {lists:reverse(SuccessCases), []};
partition_cases([Case|Rest], SuccessCases) ->
    case Case of
        ?QQ("else -> erlang:raise(error, {missing_parse_transform, _@_}, _@_)") ->
            {lists:reverse(SuccessCases), Rest};
        _ ->
            partition_cases(Rest, [Case|SuccessCases])
    end.

error_case_type([]) -> undefined;
error_case_type([?QQ("_ -> _@_")]) -> match_all;
error_case_type(_) -> match_pattern.

success_case_type(?QQ("_ -> _")) -> undefined;
success_case_type(_) -> match.

with_statement(_, undefined, undefined, Expressions, _, _) ->
    {Init, Last} = wrap_list_comprehension(Expressions),
    ?QQ("erlang:hd([_@Last || _@Init])");
with_statement(State, undefined, match_all, Expressions, _, ErrorCases) ->
    {Init, Last} = wrap_list_comprehension(Expressions),
    ?QQ("_ -> _@ErrorCase") = hd(ErrorCases),
    {Var, NewState} = success_var(State),
    {
        continue,
        ?QQ([ "case [_@Last || _@Init] of"
            , "    []      -> _@ErrorCase;"
            , "    [_@Var] -> _@Var"
            , "end"]),
        NewState
    };
with_statement(State0, undefined, match_pattern, Expressions, _, ErrorCases) ->
    {Nested, State1} = nest_list_comprehension(State0, Expressions),
    Cases = lists:map(fun wrap_error/1, ErrorCases),
    {Var, State2} = success_var(State1),
    {
        continue,
        ?QQ([ "case _@Nested of"
            , "    _@_ -> _@_Cases;"
            , "    _@Var -> _@Var"
            , "end"]),
        State2
    };
with_statement(_, match, undefined, Expressions, SuccessCases, _) ->
    {Init, Last} = wrap_list_comprehension(Expressions),
    Cases = lists:map(fun wrap_in_list/1, SuccessCases),
    ?QQ([ "case [_@Last || _@Init] of"
        , "    _@_ -> _@_Cases"
        , "end"]);
with_statement(State, _, _, Expressions, SuccessCases, ErrorCases) ->
    {Nested, NewState} = nest_list_comprehension(State, Expressions),
    Cases =
        lists:map(fun wrap_ok/1, SuccessCases) ++
        lists:map(fun wrap_error/1, ErrorCases),
    {
        continue,
        ?QQ([ "case _@Nested of"
            , "    _@_ -> _@_Cases"
            , "end"]),
        NewState
    }.

success_var(State) ->
    {Name, UpdatedState} = merlin_lib:add_new_variable(State, "__Success", "__"),
    {erl_syntax:variable(Name), UpdatedState}.

nest_list_comprehension(State, []) ->
    {[], State};
nest_list_comprehension(State, [Last]) ->
    {[?QQ("{ok, _@Last}")], State};
nest_list_comprehension(State, Expressions) ->
    {Init, Last} = split(Expressions),
    {Names, NewState} = merlin_lib:add_new_variables(State, length(Init)),
    ExpressionsWithVars = lists:zip(
        Init, lists:map(fun erl_syntax:variable/1, Names)
    ),
    Cases = lists:foldr(
        fun fold_case/2, [?QQ("{ok, _@Last}")], ExpressionsWithVars
    ),
    {Cases, NewState}.

fold_case({Form, ErrorVar}, Inner) ->
    case ?QQ("[_ || _@Form]") of
        ?QQ("[_ || _ <- _@Body]") ->
            [Body|Inner];
        ?QQ("[_ || _@Pattern = merlin_with_statement:'WHEN'() = _@Guard <- _@Body]") ->
            [?QQ([ "case _@Body of"
                    , "    _@Pattern when _@Guard ->"
                    , "        _@Inner;"
                    , "    _@ErrorVar ->"
                    , "        {error, _@ErrorVar}"
                    , "end" ])];
        ?QQ("[_ || _@Pattern <- _@Body]") when erl_syntax:type(Pattern) =:= variable ->
            [?QQ("_@Pattern = _@Body")|Inner];
        ?QQ("[_ || _@Pattern <- _@Body]") ->
            [?QQ([ "case _@Body of"
                    , "    _@Pattern  ->"
                    , "        _@Inner;"
                    , "    _@ErrorVar ->"
                    , "        {error, _@ErrorVar}"
                    , "end" ])];
        ?QQ("[_ || _ = _@Body]") ->
            [Body|Inner];
        ?QQ("[_ || _@Pattern = _@Body]") when erl_syntax:type(Pattern) =:= variable ->
            [?QQ("_@Pattern = _@Body")|Inner];
        ?QQ("[_ || _@Pattern = _@Body]") ->
            [?QQ([ "case _@Body of"
                    , "    _@Pattern  ->"
                    , "        _@Inner;"
                    , "    _@ErrorVar ->"
                    , "        {error, _@ErrorVar}"
                    , "end" ])];
        _ ->
            [Form|Inner]
    end.

wrap_ok(?QQ("_@Pattern when _@__@Guard -> _@@Body")) ->
    ?QQ("{ok, _@Pattern} when _@__Guard -> _@Body").

wrap_error(?QQ("_@Pattern when _@__@Guard -> _@@Body")) ->
    ?QQ("{error, _@Pattern} when _@__@Guard -> _@Body").

wrap_in_list(?QQ("_@Pattern when _@__@Guard -> _@@Body")) ->
    ?QQ("[_@Pattern] when _@__@Guard -> _@Body").

wrap_list_comprehension(Expressions) ->
    {Init, Last} = split(Expressions),
    Exprs = lists:map(fun wrap_list_comprehension_expression/1, Init),
    {combine_begins(Exprs), Last}.

wrap_list_comprehension_expression(Form) ->
    case ?QQ("[_ || _@Form]") of
        ?QQ("[_ || _@Pattern = merlin_with_statement:'WHEN'() = _@Guard <- _@Body]") ->
            ?QQ("[_ || _@@Combined ]") = ?QQ("[_ || _@Pattern <- [_@Body], _@Guard]"),
            Combined;
        ?QQ("[_ || _@Pattern <- _@Body]") ->
            erl_syntax:generator(Pattern, ?QQ("[_@Body]"));
        ?QQ("[_ || _@Pattern = _@Body]") ->
            erl_syntax:generator(Pattern, ?QQ("[_@Body]"));
        _ ->
            ?QQ([ "begin"
                , "    _@Form,"
                , "    true"
                , "end" ])
    end.

combine_begins([]) -> [];
combine_begins([Form]) -> [Form];
combine_begins([
    ?QQ([ "begin"
        , "    _@@FirstForm,"
        , "    true"
        , "end" ]),
    ?QQ([ "begin"
        , "    _@@SecondForm,"
        , "    true"
        , "end" ])
    | Tail
]) ->
    Combined = ?QQ([ "begin"
                    , "    _@FirstForm,"
                    , "    _@SecondForm,"
                    , "    true"
                    , "end" ]),
    combine_begins([Combined|Tail]);
combine_begins([Form|Tail]) ->
    [Form|combine_begins(Tail)].

split(List) ->
    {Init, [Last]} = lists:split(length(List) - 1, List),
    {Init, Last}.