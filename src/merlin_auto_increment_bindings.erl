-module(merlin_auto_increment_bindings).

-feature(maybe_expr, enable).

-include("merlin_quote.hrl").
-include("merlin_in.hrl").
-include("log.hrl").

-export([
    format_error/1,
    parse_transform/2
]).

parse_transform(Forms, Options) ->
    Result = transform(Forms, #{options => Options}),
    merlin:return(Result).

format_error({ambiguous_binding_usage, Name}) ->
    io_lib:format(
        "Ambiguous auto incrementing variable usage. "
        "Did you mean to write `~s_`?",
        [Name]
    );
format_error({unbound_auto_incrementing_binding, Name}) ->
    io_lib:format(
        "Missing auto incrementing variable `~s@`.",
        [Name]
    );
format_error({unknown_return, Unknown}) ->
    io_lib:format(
        "Internal error: Unexpected result from match transforms ~tp",
        [Unknown]
    );
format_error(UnknownReason) ->
    Message = merlin_lib:format_error(UnknownReason),
    io_lib:format("Unknown error: ~s", [Message]).

transform(Forms, State) ->
    merlin:transform(Forms, fun transform_pin_operator/3, State).

transform_pin_operator(enter, ?QQ("_@Function"), State)
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
transform_pin_operator(enter, ?QQ("_@Pattern0 = _@Body0"), State) ->
    maybe
        {[Body1], State1} ?= transform([Body0], State),
        {[Pattern1], State2} ?= transform([Pattern0], State1),
        {return, ?QQ("_@Pattern1 = _@Body1"), State2}
    else
        {Failure, State3} when is_map(State3) ->
            {parse_transform, Failure, State3};
        Unknown ->
            {error, {unknown_return, Unknown}}
    end;
transform_pin_operator(enter, ?QQ("_@Case") = Form, State)
    when erl_syntax:type(Case) ?in [case_expr, if_expr]
->
    {continue, Form, State#{
        previous => State
    }};
transform_pin_operator(enter, ?QQ("_@Case") = Form, State)
    when erl_syntax:type(Case) =:= clause
->
    case State of
        #{ previous := #{ auto_bindings := Bindings } } ->
            {continue, Form, State#{
                auto_bindings := Bindings
            }};
        _ ->
            continue
    end;
transform_pin_operator(leaf, ?QQ("_@Var"), State)
    when auto_incrementable(Var)
->
    #{ auto_bindings := Bindings } = State,
    Name = lists:droplast(erl_syntax:variable_literal(Var)),
    NextIndex = maps:get(Name, Bindings, -1) + 1, %% Start at 0
    Var1 = erl_syntax:variable(Name ++ integer_to_list(NextIndex)),
    Var2 = erl_syntax:copy_attrs(Var, Var1),
    {Var2, State#{ auto_bindings := Bindings#{ Name => NextIndex } }};
transform_pin_operator(leaf, ?QQ("_@Var"), State)
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
transform_pin_operator(leaf, ?QQ("_@Var"), State)
    when erl_syntax:type(Var) =:= variable
->
    #{ auto_bindings := Bindings } = State,
    Name = erl_syntax:variable_literal(Var),
    case maps:is_key(Name, Bindings) of
        false -> continue;
        true -> {error, {ambiguous_binding_usage, Name}}
    end;
transform_pin_operator(exit, ?QQ("_@Case") = Form, State)
    when erl_syntax:type(Case) =:= case_expr
->
    PreviousState = maps:get(previous, State),
    {continue, Form, PreviousState};
transform_pin_operator(_, _, _) ->
    continue.

auto_incrementable(Var) ->
    erl_syntax:type(Var) =:= variable andalso
        lists:suffix("@", erl_syntax:variable_literal(Var)).

is_pinnable(Var) ->
    erl_syntax:type(Var) =:= variable andalso
        lists:suffix("_", erl_syntax:variable_literal(Var)).
