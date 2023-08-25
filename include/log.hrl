-ifndef(MERLIN_LOG_HRL).
-define(MERLIN_LOG_HRL, true).

%% Should be set to one of the logger logging levels
-ifndef(MERLIN_LOG_LEVEL).
-define(MERLIN_LOG_LEVEL, warning).
-endif.

%% Translate the nice atom based log levels to the
%% integer based ones used by logger.
%%
%% See logger_internal.hrl for details
-if(?MERLIN_LOG_LEVEL =:= none).
-undef(MERLIN_LOG_LEVEL).
-define(MERLIN_LOG_LEVEL, -1).
-elif(?MERLIN_LOG_LEVEL =:= emergency).
-undef(MERLIN_LOG_LEVEL).
-define(MERLIN_LOG_LEVEL, 0).
-elif(?MERLIN_LOG_LEVEL =:= alert).
-undef(MERLIN_LOG_LEVEL).
-define(MERLIN_LOG_LEVEL, 1).
-elif(?MERLIN_LOG_LEVEL =:= critical).
-undef(MERLIN_LOG_LEVEL).
-define(MERLIN_LOG_LEVEL, 2).
-elif(?MERLIN_LOG_LEVEL =:= error).
-undef(MERLIN_LOG_LEVEL).
-define(MERLIN_LOG_LEVEL, 3).
-elif(?MERLIN_LOG_LEVEL =:= warning).
-undef(MERLIN_LOG_LEVEL).
-define(MERLIN_LOG_LEVEL, 4).
-elif(?MERLIN_LOG_LEVEL =:= notice).
-undef(MERLIN_LOG_LEVEL).
-define(MERLIN_LOG_LEVEL, 5).
-elif(?MERLIN_LOG_LEVEL =:= info).
-undef(MERLIN_LOG_LEVEL).
-define(MERLIN_LOG_LEVEL, 6).
-elif(?MERLIN_LOG_LEVEL =:= debug).
-undef(MERLIN_LOG_LEVEL).
-define(MERLIN_LOG_LEVEL, 7).
-elif(?MERLIN_LOG_LEVEL =:= all).
-undef(MERLIN_LOG_LEVEL).
-define(MERLIN_LOG_LEVEL, 10).
-endif.

-if(?MERLIN_LOG_LEVEL >= 7).
-define(debug(A), ?log(debug, A)).
-define(debug(A, B), ?log(debug, A, B)).
-define(debug(A, B, C), ?log(debug, A, B, C)).
-else.
-define(debug(A), ok).
-define(debug(A, B), ok).
-define(debug(A, B, C), ok).
-endif.

-if(?MERLIN_LOG_LEVEL >= 6).
-define(info(A), ?log(info, A)).
-define(info(A, B), ?log(info, A, B)).
-define(info(A, B, C), ?log(info, A, B, C)).
-else.
-define(info(A), ok).
-define(info(A, B), ok).
-define(info(A, B, C), ok).
-endif.

-if(?MERLIN_LOG_LEVEL >= 5).
-define(notice(A), ?log(notice, A)).
-define(notice(A, B), ?log(notice, A, B)).
-define(notice(A, B, C), ?log(notice, A, B, C)).
-else.
-define(notice(A), ok).
-define(notice(A, B), ok).
-define(notice(A, B, C), ok).
-endif.

-if(?MERLIN_LOG_LEVEL >= 4).
-define(warning(A), ?log(warning, A)).
-define(warning(A, B), ?log(warning, A, B)).
-define(warning(A, B, C), ?log(warning, A, B, C)).
-else.
-define(warning(A), ok).
-define(warning(A, B), ok).
-define(warning(A, B, C), ok).
-endif.

-if(?MERLIN_LOG_LEVEL >= 3).
-define(error(A), ?log(error, A)).
-define(error(A, B), ?log(error, A, B)).
-define(error(A, B, C), ?log(error, A, B, C)).
-else.
-define(error(A), ok).
-define(error(A, B), ok).
-define(error(A, B, C), ok).
-endif.

-if(?MERLIN_LOG_LEVEL >= 2).
-define(critical(A), ?log(critical, A)).
-define(critical(A, B), ?log(critical, A, B)).
-define(critical(A, B, C), ?log(critical, A, B, C)).
-else.
-define(critical(A), ok).
-define(critical(A, B), ok).
-define(critical(A, B, C), ok).
-endif.

-if(?MERLIN_LOG_LEVEL >= 1).
-define(alert(A), ?log(alert, A)).
-define(alert(A, B), ?log(alert, A, B)).
-define(alert(A, B, C), ?log(alert, A, B, C)).
-else.
-define(alert(A), ok).
-define(alert(A, B), ok).
-define(alert(A, B, C), ok).
-endif.

-if(?MERLIN_LOG_LEVEL >= 0).
-define(emergency(A), ?log(emergency, A)).
-define(emergency(A, B), ?log(emergency, A, B)).
-define(emergency(A, B, C), ?log(emergency, A, B, C)).
-else.
-define(emergency(A), ok).
-define(emergency(A, B), ok).
-define(emergency(A, B, C), ok).
-endif.

-define(__logger_metadata, #{
    mfa => {?MODULE, ?FUNCTION_NAME, ?FUNCTION_ARITY},
    file => ?FILE,
    line => ?LINE,
    domain => [
        list_to_atom(Part)
     || Part <- string:split(erlang:atom_to_list(?MODULE), "_", all)
    ]
}).

-define(__if_logging_allowed(Level, Expression),
    case logger_config:allow(Level, ?MODULE) of
        true -> Expression;
        false -> ok
    end
).

-define(log(Level, StringOrReport),
    ?__if_logging_allowed(
        Level,
        logger:log(Level, StringOrReport, ?__logger_metadata)
    )
).

-define(log(Level, FunOrFormat, ArgsOrMetadata),
    ?__if_logging_allowed(
        Level,
        merlin_internal:log_macro(
            Level,
            FunOrFormat,
            ArgsOrMetadata,
            ?__logger_metadata
        )
    )
).

-define(log(Level, FunOrFormat, Args, Metadata),
    ?__if_logging_allowed(
        Level,
        logger:log(
            Level,
            FunOrFormat,
            Args,
            maps:merge(?__logger_metadata, Metadata)
        )
    )
).

-define(log_exception(Class, Reason, Stacktrace),
    ?debug(
        "~s(~tp)~n~ts~n",
        [Class, Reason, merlin_internal:format_stack(Stacktrace)]
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
    (fun(X__Forms) ->
        {X__Format, X__Args} = merlin_internal:format_forms({??Expr " = ", X__Forms}),
        io:format(X__Format ++ "~n", X__Args),
        X__Forms
    end)(
        Expr
    )
end).

-define(ppr(Expr), ?pp(merlin:revert(Expr))).

-define(ppt(Expr), begin
    (fun(X__Forms, {current_stacktrace, X__Stacktrace}) ->
        {X__Format, X__Args} = merlin_internal:format_forms({??Expr " = ", X__Forms}),
        io:format(
            X__Format ++ "~n~ts~n",
            X__Args ++ [merlin_internal:format_stack(X__Stacktrace)]
        ),
        X__Forms
    end)(
        Expr,
        erlang:process_info(self(), current_stacktrace)
    )
end).

-define(var(Expr), begin
    (fun(X__Term) ->
        io:format("~ts =~n~tp~n", [??Expr, X__Term]),
        X__Term
    end)(
        Expr
    )
end).

-define(varr(Expr), ?var(merlin:revert(Expr))).

-define(vart(Expr), begin
    (fun(X__Term, {current_stacktrace, X__Stacktrace}) ->
        io:format("~ts =~n~tp~n~ts~n", [
            ??Expr,
            X__Term,
            merlin_internal:format_stack(X__Stacktrace)
        ]),
        X__Term
    end)(
        Expr,
        erlang:process_info(self(), current_stacktrace)
    )
end).

-define(varrt(Expr), ?var(merlin:revert(Expr))).

-endif.
