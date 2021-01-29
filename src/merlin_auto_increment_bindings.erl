-module(merlin_auto_increment_bindings).

-include("merlin_quote.hrl").
-include("merlin_with_statement.hrl").
-include("log.hrl").

-export([
    format_error/1,
    parse_transform/2
]).

parse_transform(Forms, Options) ->
    Result = transform(Forms, #{ options => Options }),
    merlin:return(Result).

transform(Forms, State) ->
    merlin:transform(Forms, fun transforme_pin_operator/3, State).

format_error({ambiguous_binding_usage, Name}) ->
    io_lib:format(
        "Ambiguous auto incrementing variable usage."
        "Did you mean to write `~s_`?",
        [Name]
    );
format_error({unbound_auto_incrementing_binding, Name}) ->
    io_lib:format(
        "Missing auto incrementing variable `~s@`.", [Name]
    );
format_error({unknow_return, Unknown}) ->
    io_lib:format(
        "Internal error: Unexpected result from match transforms ~tp",
        [Unknown]
    );
format_error(UnknownReason) ->
    Message = merlin_lib:format_error(UnknownReason),
    io_lib:format("Unknown error: ~s", [Message]).

transforme_pin_operator(enter, ?QQ("_@Function"), State)
    when erl_syntax:type(Function) =:= function
->
    {continue, Function, State#{
        auto_bindings => #{},
        all_bindings => ordsets:from_list(
            lists:map(
                fun atom_to_list/1, sets:to_list(erl_syntax_lib:variables(Function))
            )
        )
    }};
transforme_pin_operator(enter, ?QQ("_@Pattern0 = _@Body0"), State) ->
    ?with [_ ||
        {[Body1], State1} = transform([Body0], State),
        {[Pattern1], State2} = transform([Pattern0], State1),
        Match0 = erl_syntax:match_expr(Pattern1, Body1),
        Match1 = erl_syntax:copy_attrs(__NODE__, Match0),
        {return, Match1, State2}
    ] of
        Return ->
            Return
    ?else
        {warning, Forms, Warnings} ->
            Warnings1 = revert_exceptions(Warnings, warning),
            {exceptions, Warnings1, Forms, State};
        {error, Errors, Warnings} ->
            Errors1 = revert_exceptions(Errors, error),
            Warnings1 = revert_exceptions(Warnings, warning),
            {exceptions, Errors1 ++ Warnings1, __NODE__, State};
        Unknown ->
            {error, {unknow_return, Unknown}}

    end;
transforme_pin_operator(leaf, ?QQ("_@Var"), State)
    when auto_incrementable(Var)
->
    #{ auto_bindings := Bindings } = State,
    Name = lists:droplast(erl_syntax:variable_literal(Var)),
    NextIndex = maps:get(Name, Bindings, -1) + 1, %% Start at 0
    Var1 = erl_syntax:variable(Name ++ integer_to_list(NextIndex)),
    Var2 = erl_syntax:copy_attrs(Var, Var1),
    {Var2, State#{ auto_bindings := Bindings#{ Name => NextIndex } }};
transforme_pin_operator(leaf, ?QQ("_@Var"), State)
    when is_pinnable(Var)
->
    #{
        auto_bindings := Bindings,
        all_bindings := All
    } = State,
    Name = lists:droplast(erl_syntax:variable_literal(Var)),
    case maps:get(Name, Bindings, undefined) of
        undefined ->
            case ordsets:is_element(Name ++ "@", All) of
                false ->
                    return;
                true ->
                    {error, {unbound_auto_incrementing_binding, Name}}
            end;
        Index ->
            CurrentVar = erl_syntax:variable(Name ++ integer_to_list(Index)),
            erl_syntax:copy_attrs(Var, CurrentVar)
    end;
transforme_pin_operator(leaf, ?QQ("_@Var"), State)
    when erl_syntax:type(Var) =:= variable
->
    #{ auto_bindings := Bindings } = State,
    Name = erl_syntax:variable_name(Var),
    case maps:is_key(Name, Bindings) of
        false -> continue;
        true -> {error, {ambiguous_binding_usage, Name}}
    end;
transforme_pin_operator(_, _, _) ->
    continue.

auto_incrementable(Var) ->
    erl_syntax:type(Var) =:= variable
    andalso lists:suffix("@", erl_syntax:variable_literal(Var)).

is_pinnable(Var) ->
    erl_syntax:type(Var) =:= variable
    andalso lists:suffix("_", erl_syntax:variable_literal(Var)).

revert_exceptions(Exceptions, Type) ->
    [
        {Type, Marker}
    ||
        {_File, Marker} <- Exceptions
    ].