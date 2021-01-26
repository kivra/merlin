-ifndef(MERLIN_MACROS).
-define(MERLIN_MACROS, true).

-compile({parse_transform, merlin_macros_transform}).

-define(procedural(MACRO, BODY),
    merlin_internal:'DEFINE PROCEDURAL MACRO'(
        ?FILE,
        ?LINE,
        ?MODULE_STRING,
        ?FUNCTION_NAME,
        ?FUNCTION_ARITY,
        ??MACRO,
        %% Avoid evaluating the body at runtime if the parse transform wasn't
        %% enabled. This allows a better error to be raised by the internal
        %% (dummy) function.
        fun() -> BODY end
    )
).

-define(module_procedural(MACRO, BODY),
    'MERLIN INTERNAL DEFINE PROCEDURAL MACRO'() ->
        ?FILE,
        ?LINE,
        ?MODULE_STRING,
        ??MACRO,
        BODY
).

-define(eval(Expression), ?procedural(eval(Expression),
    erl_parse:abstract(Expression, ?LINE)
)).

-define(hygienic(MACRO, BODY), ?procedural(hygienic(MACRO, BODY), begin
    [Body] = abstract(BODY),
    Variables = erl_syntax_lib:variables(Body),
    VariableMapping = maps:from_list(lists:zip(
        sets:to_list(Variables),
        merlin_lib:new_variables(Variables, sets:size(Variables))
    )),
    {[Form], _} = merlin:transform(
        [Body],
        fun(leaf, Node, Map) ->
            case erl_syntax:type(Node) =:= variable of
                false -> continue;
                true ->
                    Name = erl_syntax:variable_name(Node),
                    NewName = maps:get(Name, Map, Name),
                    NewVariable = erl_syntax:variable(NewName),
                    erl_syntax:copy_attrs(Node, NewVariable)
            end;
            (_, _, _) -> continue
        end,
        VariableMapping
    ),
    Form
end)).

-endif.