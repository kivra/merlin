-ifndef(MERLIN_WITH_STATEMENT).
-define(MERLIN_WITH_STATEMENT, true).

-compile({parse_transform, merlin_with_statement}).

%% This makes it look like a real keyword `?with [...] of' instead of
%% `?with([...]) of'
-define(with, case merlin_with_statement:'MARKER'() and).

-define(with(Expressions),
    ?with Expressions of _ -> _ end
).

-define(when_, = merlin_with_statement:'WHEN'() =).

-define(else,
    ; else ->
        erlang:raise(error, {missing_parse_transform,
            "To use the with statement you must enable the merlin with "
            "statement parse transform."
        }, [{?MODULE, ?FUNCTION_NAME, ?FUNCTION_ARITY,
                [{file, ?FILE}, {line, ?LINE}]}]);
).

-endif.
