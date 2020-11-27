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

-define(hygienic(MACRO, BODY), ?procedural(hygienic(MACRO, BODY),
    BODY % Implement hygine, aka rename variables
)).

-endif.