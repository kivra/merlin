-define(debug(A),           ?log(debug, A)).
-define(debug(A, B),        ?log(debug, A, B)).
-define(debug(A, B, C),     ?log(debug, A, B, C)).

-define(info(A),            ?log(info, A)).
-define(info(A, B),         ?log(info, A, B)).
-define(info(A, B, C),      ?log(info, A, B, C)).

-define(notice(A),          ?log(notice, A)).
-define(notice(A, B),       ?log(notice, A, B)).
-define(notice(A, B, C),    ?log(notice, A, B, C)).

-define(warning(A),         ?log(warning, A)).
-define(warning(A, B),      ?log(warning, A, B)).
-define(warning(A, B, C),   ?log(warning, A, B, C)).

-define(error(A),           ?log(error, A)).
-define(error(A, B),        ?log(error, A, B)).
-define(error(A, B, C),     ?log(error, A, B, C)).

-define(critical(A),        ?log(critical, A)).
-define(critical(A, B),     ?log(critical, A, B)).
-define(critical(A, B, C),  ?log(critical, A, B, C)).

-define(alert(A),           ?log(alert, A)).
-define(alert(A, B),        ?log(alert, A, B)).
-define(alert(A, B, C),     ?log(alert, A, B, C)).

-define(emergency(A),       ?log(emergency, A)).
-define(emergency(A, B),    ?log(emergency, A, B)).
-define(emergency(A, B, C), ?log(emergency, A, B, C)).

-define(__logger_metadata, #{
    mfa => {?MODULE, ?FUNCTION_NAME, ?FUNCTION_ARITY},
    file => ?FILE,
    line => ?LINE,
    domain => [
        list_to_atom(Part)
    ||
        Part <- string:split(erlang:atom_to_list(?MODULE), "_", all)
    ]
}).

-define(__if_logging_allowed(Level, Expression),
    case logger_config:allow(Level, ?MODULE) of
        true -> Expression;
        false -> ok
    end
).

-define(log(Level, StringOrReport),
    ?__if_logging_allowed(Level,
        logger:log(Level, StringOrReport, ?__logger_metadata)
    )
).

-define(log(Level, FunOrFormat, ArgsOrMetadata),
    ?__if_logging_allowed(Level,
        merlin_internal:log_macro(
            Level, FunOrFormat, ArgsOrMetadata, ?__logger_metadata
        )
    )
).

-define(log(Level, FunOrFormat, Args, Metadata),
    ?__if_logging_allowed(Level,
        logger:log(
            Level, FunOrFormat, Args, maps:merge(?__logger_metadata, Metadata)
        )
    )
).

-define(log_exception(Class, Reason, Stacktrace),
    ?debug(
        "~s(~tp)~n~s~n", [Class, Reason, merlin_internal:format_stack(Stacktrace)]
    )
).

-define(show(Forms), ?show("", Forms)).

-define(show(Prefix, Forms), ?show(debug, Prefix, Forms)).

-define(show(Level, Prefix, Forms), ?show(Level, Prefix, Forms, #{})).

-define(show(Level, Prefix, Forms, Metadata),
    ?log(Level, fun merlin_internal:format_forms/1, {Prefix, Forms}, Metadata)
).

-define(stacktrace,
    merlin_internal:print_stacktrace(process_info(self(), current_stacktrace))
).

-define(pp(Expr), begin
    (fun(Forms) ->
        {Format, Args} = merlin_internal:format_forms({??Expr " = ", Forms}),
        io:format(Format ++ "~n", Args),
        Forms
    end)(Expr)
end).

-define(ppr(Expr), ?pp(merlin:revert(Expr))).

-define(ppt(Expr), begin
    (fun(Forms, {current_stacktrace, Stacktrace}) ->
        {Format, Args} = merlin_internal:format_forms({??Expr " = ", Forms}),
        io:format(Format ++ "~n~s~n", Args ++ [merlin_internal:format_stack(Stacktrace)]),
        Forms
    end)(Expr, erlang:process_info(self(), current_stacktrace))
end).

-define(var(Expr), begin
    (fun(Term) ->
        io:format("~s =~n~p~n", [??Expr, Term]),
        Term
    end)(Expr)
end).

-define(varr(Expr), ?var(merlin:revert(Expr))).

-define(vart(Expr), begin
    (fun(Term, {current_stacktrace, Stacktrace}) ->
        io:format("~s =~n~p~n~s~n", [??Expr, Term, merlin_internal:format_stack(Stacktrace)]),
        Term
    end)(Expr, erlang:process_info(self(), current_stacktrace))
end).

-define(varrt(Expr), ?var(merlin:revert(Expr))).
