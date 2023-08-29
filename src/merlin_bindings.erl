%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Module for manipulating bindings, more commonly known as variables.
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%_* Module declaration =====================================================
-module(merlin_bindings).

%%%_* Exports ================================================================
%%%_ * API -------------------------------------------------------------------
-export([
    annotate/1,
    annotate/2,
    get/2,
    get_by_state/2,
    has/1,
    has/2,
    has/3,
    new/1,
    new/2
]).

-ifdef(TEST).
-export([
    reset_uniqueness_counter/0
]).
-endif.

%%%_* Types ------------------------------------------------------------------
-export_type([
    binding_mapping/0,
    bindings/0,
    state/0,
    variable/0
]).

%%%_* Includes ===============================================================
-include("internal.hrl").
-include("assertions.hrl").

-ifdef(TEST).
-include("merlin_test.hrl").
-include("log.hrl").
-endif.

%%%_* Macros =================================================================
-define(DEFAULT_FORMAT_STRING, "var-~tp").

-define(is_binding_state(State), ?oneof(State, env, bound, free)).

%%%_* Types ==================================================================
-type state() :: env | bound | free.
%% Represents the state a binding can be in.
%%
%% <dl>
%% <dt>`env'</dt>
%% <dd>Bindings from the surrounding scope, i.e. a `fun''s closure.</dd>
%% <dt>`bound'</dt>
%% <dd>Bindings with value.</dd>
%% <dt>`free'</dt>
%% <dd>Bindings without a value. It's a compile time error to try to access them.</dd>
%% </dl>

-type bindings() :: ordsets:ordset(atom()).
%% Represents a set of bindings.
%%
%% Each binding is its name as an atom.

-type binding_mapping() :: #{
    env := bindings(),
    bound := bindings(),
    free := bindings()
}.
%% Represents the current set of bindings for a node.
%%
%% @see annotate/1

-type variable() :: merlin:ast().
%% Represents a {@link erl_syntax:variable/1. variable} binding.

%%%_* Code ===================================================================
%%%_ * API -------------------------------------------------------------------
%% @doc Returns the given node {@link annotate/1. annotated} with detailed
%% information about its bindings.
%%
%% Fetches the starting (`env') bindings from the node itself, defaulting to an
%% empty set if none are found. This is in contrast to
%% {@link erl_syntax_lib:annotate_bindings/1} that crashes if no such bindings
%% can be found.
%%
%% @see annotate/2
-spec annotate(merlin:ast()) -> merlin:ast().
annotate(Nodes) when is_list(Nodes) ->
    lists:map(fun annotate/1, Nodes);
annotate(Node) ->
    ?assertIsNode(Node),
    EnvBindings = merlin_annotations:get(Node, env, ordsets:new()),
    annotate(Node, EnvBindings).

%% @doc Returns the given node
%% {@link erl_syntax_lib:annotate_bindings/2. annotated} with detailed
%% information about its bindings using the given bindings as a starting
%% point.
%%
%% @see erl_syntax_lib:annotate_bindings/2
-spec annotate(merlin:ast(), bindings()) -> merlin:ast().
annotate(Nodes, EnvBindings) when is_list(Nodes) ->
    [annotate(Node, EnvBindings) || Node <- Nodes];
annotate(Node, EnvBindings) ->
    ?assertIsNode(Node),
    erl_syntax_lib:annotate_bindings(Node, EnvBindings).

%% @doc Returns `true' if the given node has been
%% {@link annotate/1. annotated} with its bindings.
-spec has(merlin:ast()) -> boolean().
-ifndef(NOASSERT).
has(Node) ->
    Has =
        merlin_annotations:has(Node, env) andalso
            merlin_annotations:has(Node, bound) andalso
            merlin_annotations:has(Node, free),
    case Has of
        true ->
            ?assert(
                ordsets:is_set(merlin_annotations:get(Node, env)),
                "env bindings must be an ordset"
            ),
            ?assert(
                ordsets:is_set(merlin_annotations:get(Node, bound)),
                "bound bindings must be an ordset"
            ),
            ?assert(
                ordsets:is_set(merlin_annotations:get(Node, free)),
                "free bindings must be an ordset"
            ),
            true;
        false ->
            false
    end.
-else.
has(Node) ->
    merlin_annotations:has(Node, env) andalso
        merlin_annotations:has(Node, bound) andalso
        merlin_annotations:has(Node, free).
-endif.

%% @doc Returns `true' if the given node has a binding with the given name.
-spec has(merlin:ast(), Binding) -> boolean() when
    Binding :: atom() | string().
has(Node, Binding0) when is_atom(Binding0) orelse ?is_string(Binding0) ->
    #{env := Env, bound := Bound, free := Free} = get_binding_annotations([
        Node, Binding0
    ]),
    Binding1 = binding_to_atom(Binding0),
    %% Ordered by what is assumed to be the most common case.
    ordsets:is_element(Binding1, Env) orelse
        ordsets:is_element(Binding1, Bound) orelse
        ordsets:is_element(Binding1, Free).

%% @doc Returns `true' if the given node has a binding with the given name in
%% the given state.
-spec has(merlin:ast(), Binding, state()) -> boolean() when
    Binding :: atom() | string().
has(Node, Binding, State) when
    is_atom(Binding) orelse ?is_string(Binding) andalso ?is_binding_state(State)
->
    #{env := Env, bound := Bound, free := Free} = get_binding_annotations([
        Node, Binding, State
    ]),
    Binding1 = binding_to_atom(Binding),
    case State of
        env -> ordsets:is_element(Binding1, Env);
        bound -> ordsets:is_element(Binding1, Bound);
        free -> ordsets:is_element(Binding1, Free)
    end.

%% @doc Returns the bindings for the given node in the given state.
%%
%% The given node, or one of its ancestors, must have been
%% {@link annotate/1. annotated} with its bindings.
-spec get_by_state(merlin:ast(), state()) -> bindings().
-ifndef(NOASSERT).
get_by_state(Node, State) when ?is_binding_state(State) ->
    Bindings = merlin_annotations:get(Node, State),
    ?assert(
        ordsets:is_set(Bindings), atom_to_list(State) ++ " must be an ordset"
    ),
    Bindings.
-else.
get_by_state(Node, State) when ?is_binding_state(State) ->
    merlin_annotations:get(Node, State).
-endif.

%% @doc Returns the {@link state()} for given binding in the given node.
%%
%% Prefers `bound' over `env' over `free' over `unbound'. The latter means
%% that the given binding does not occur in the given node, unlike free which
%% means that the binding will occur later.
%%
%% The given node, or one of its ancestors, must have been
%% {@link annotate/1. annotated} with its bindings.
-spec get(merlin:ast(), Binding) -> state() | unbound when
    Binding :: atom() | string().
get(Node, Binding) when is_atom(Binding) orelse ?is_string(Binding) ->
    #{env := Env, bound := Bound, free := Free} = get_binding_annotations([
        Node, Binding
    ]),
    Binding1 = binding_to_atom(Binding),
    case ordsets:is_element(Binding1, Bound) of
        true ->
            bound;
        false ->
            case ordsets:is_element(Binding1, Env) of
                true ->
                    env;
                false ->
                    case ordsets:is_element(Binding1, Free) of
                        true -> free;
                        false -> unbound
                    end
            end
    end.

%% @doc Returns a new {@link erl_syntax:variable/1. variable} binding
%% guaranteed to be unique with respect to the current set of bindings in the
%% given node.
%%
%% The variable will have its {@link erl_syntax:copy_attrs/2. attributes} copied
%% from the given node. This means both user annotations, position information,
%% and comments are taken from the given node. In practice it means that
%% stacktraces will point to a more correct location rather then the top of the
%% file.
%%
%% The given node's bindings will be updated to reflect the new variable.
-spec new(Node) -> {Node, variable()} when
    Node :: merlin:ast().
new(Node) ->
    new(Node, #{total => 1}).

%% @doc Returns new {@link erl_syntax:variable/1. variable(s)} binding
%% according to the given options.
%%
%% The options may specify a `format' string, which is used to generate the
%% variable name. The format string must contain a single `~tp' which is used to
%% ensure uniqueness.
%%
%% You may also specify a `total' option, which is used to generate multiple
%% variables.
%%
%% Both the format string and the total option can be passed directly as a
%% short hand.
%%
%% @see new/1
-spec new(Node, Format | Total | Options) -> {Node, variable() | [variable()]} when
    Node :: merlin:ast(),
    Format :: io:format(),
    Total :: pos_integer(),
    Options :: #{
        file => string(),
        format => Format,
        location => erl_anno:location(),
        total => Total
    }.
new(Node, Format) when ?is_string(Format) ->
    new(Node, #{format => Format, total => 1});
new(Node, Total) when ?is_pos_integer(Total) ->
    new(Node, #{total => Total});
new(Node0, Options) when is_map(Options) ->
    #{env := Env, bound := Bound, free := Free} = get_binding_annotations([
        Node0, Options
    ]),
    ExistingBindings = ordsets:union([Env, Bound, Free]),
    Format = maps:get(format, Options, ?DEFAULT_FORMAT_STRING),
    Total = maps:get(total, Options, 1),
    UniquenessCounterKey0 =
        case merlin_annotations:get(Node0, file, undefined) of
            undefined -> maps:get(file, Options, <<>>);
            File -> File
        end,
    UniquenessCounterKey1 = unicode:characters_to_binary([
        <<"merlin_binding_counter:">>, UniquenessCounterKey0, $:, Format
    ]),
    UniquenessCounter1 =
        case erlang:get(UniquenessCounterKey1) of
            undefined -> 0;
            UniquenessCounter0 -> UniquenessCounter0
        end,
    State = Options#{
        bindings => ExistingBindings,
        format => Format,
        total => Total,
        uniqueness_counter => UniquenessCounter1
    },
    case new_unique_variables(Node0, State, []) of
        {Node1, #{uniqueness_counter := UniquenessCounter2}, [Variable]} ->
            ?assertMatch(#{total := 1}, State),
            erlang:put(UniquenessCounterKey1, UniquenessCounter2),
            {Node1, Variable};
        {Node1, #{uniqueness_counter := UniquenessCounter2}, Variables} ->
            ?assertMatch(#{total := Total} when length(Variables) =:= Total, State),
            erlang:put(UniquenessCounterKey1, UniquenessCounter2),
            {Node1, Variables}
    end.

-ifdef(TEST).
reset_uniqueness_counter() ->
    lists:foreach(
        fun
            ({<<"merlin_binding_counter:", _/bytes>> = Key, _Value}) ->
                erlang:erase(Key);
            (_) ->
                ok
        end,
        erlang:get()
    ).

-endif.

%%%_* Private ----------------------------------------------------------------
get_binding_annotations([Node | _]) ->
    #{
        env => get_by_state(Node, env),
        bound => get_by_state(Node, bound),
        free => get_by_state(Node, free)
    }.

new_unique_variables(Node, #{total := 0} = State, Result) when is_list(Result) ->
    {Node, State, lists:reverse(Result)};
new_unique_variables(Node0, #{total := Total} = State0, Result) when
    ?is_pos_integer(Total)
->
    {Node1, State1, Variable} = new_unique_variable(Node0, State0),
    new_unique_variables(Node1, State1#{total => Total - 1}, [Variable | Result]).

new_unique_variable(
    Node0,
    #{
        uniqueness_counter := UniquenessCounter,
        format := Format,
        bindings := ExistingBindings
    } = State0
) ->
    ?assertRegexpMatch("^[^~]*~t?p[^~]*$", Format),
    VariableName = binary_to_atom(
        unicode:characters_to_binary(
            io_lib:format(Format, [UniquenessCounter])
        )
    ),
    case ordsets:is_element(VariableName, ExistingBindings) of
        true ->
            new_unique_variable(Node0, State0#{
                uniqueness_counter := UniquenessCounter + 1
            });
        false ->
            State1 = State0#{
                bindings := ordsets:add_element(VariableName, ExistingBindings)
            },
            Node1 = merlin_annotations:merge(Node0, #{
                bound => ordsets:add_element(
                    VariableName, merlin_annotations:get(Node0, bound)
                ),
                free => ordsets:del_element(
                    VariableName, merlin_annotations:get(Node0, free)
                )
            }),
            Variable0 = erl_syntax:variable(VariableName),
            Variable1 = erl_syntax:copy_attrs(Node1, Variable0),
            Variable2 = merlin_annotations:set(Variable1, generated, true),
            Variable3 = merlin_annotations:merge(
                Variable2, maps:with([location, file], State1)
            ),
            {Node1, State1, Variable3}
    end.

binding_to_atom(Binding) when is_atom(Binding) ->
    Binding;
binding_to_atom(Binding) when ?is_string(Binding) ->
    list_to_atom(Binding).

%%%_* Tests ==================================================================
-ifdef(TEST).

annotate_test_() ->
    [
        ?_quickcheck(
            module_forms_type(),
            ModuleForms,
            annotate(ModuleForms) =:=
                [
                    erl_syntax_lib:annotate_bindings(Form, ordsets:new())
                 || Form <- ModuleForms
                ]
        ),
        ?_quickcheck(
            {module_forms_type(), variables_type()},
            {ModuleForms, EnvBindings},
            annotate(ModuleForms, EnvBindings) =:=
                [
                    erl_syntax_lib:annotate_bindings(Form, EnvBindings)
                 || Form <- ModuleForms
                ]
        )
    ].

new_test_() ->
    maps:to_list(#{
        "default/no options" => ?_quickcheck(
            expression_with_annotated_bindings(),
            Node0,
            begin
                ExistingBindings = get_existing_bindings(Node0),
                {Node1, Variable} = new(Node0),
                ?assertIsNode(Node1),
                ?assertNodeType(Variable, variable),
                NewBindings = get_existing_bindings(Node1),
                Bindings = ordsets:subtract(NewBindings, ExistingBindings),
                ?assertMatch(_ when length(Bindings) =:= 1, Bindings),
                ?assertEqual([], missing_bindings(Bindings, [Variable]))
            end
        ),
        "with total > 1" => ?_quickcheck(
            {expression_with_annotated_bindings(), pos_integer_type()},
            {Node0, Total0},
            begin
                %% Ensure total > 1
                Total1 = Total0 + 1,
                ExistingBindings = get_existing_bindings(Node0),
                {Node1, Variables} = new(Node0, Total1),
                ?assertIsNode(Node1),
                ?assertEqual(Total1, length(Variables)),
                lists:foreach(
                    fun(Variable) ->
                        ?assertNodeType(Variable, variable)
                    end,
                    Variables
                ),
                NewBindings = get_existing_bindings(Node1),
                Bindings = ordsets:subtract(NewBindings, ExistingBindings),
                ?assertMatch(_ when length(Bindings) =:= Total1, Bindings),
                ?assertEqual([], missing_bindings(Bindings, Variables))
            end
        ),
        "with custom format" => ?_quickcheck(
            {expression_with_annotated_bindings(), format_option_type()},
            {Node0, Format},
            begin
                ExistingBindings = get_existing_bindings(Node0),
                {Node1, Variable} = new(Node0, Format),
                ?assertIsNode(Node1),
                ?assertNodeType(Variable, variable),
                NewBindings = get_existing_bindings(Node1),
                Bindings = ordsets:subtract(NewBindings, ExistingBindings),
                ?assertMatch(_ when length(Bindings) =:= 1, Bindings),
                ?assertEqual([], missing_bindings(Bindings, [Variable]))
            end
        ),
        "with file option" => ?_quickcheck(
            {expression_with_annotated_bindings(), file_option_type()},
            {Node0, File},
            begin
                ExistingBindings = get_existing_bindings(Node0),
                {Node1, Variable} = new(Node0, #{file => File}),
                ?assertIsNode(Node1),
                ?assertNodeType(Variable, variable),
                NewBindings = get_existing_bindings(Node1),
                Bindings = ordsets:subtract(NewBindings, ExistingBindings),
                ?assertMatch(_ when length(Bindings) =:= 1, Bindings),
                ?assertEqual([], missing_bindings(Bindings, [Variable]))
            end
        ),
        "with options" => ?_quickcheck(
            {expression_with_annotated_bindings(), new_options_type()},
            {Node0, Options},
            begin
                ExistingBindings = get_existing_bindings(Node0),
                {Node1, VariableOrVariables} = new(Node0, Options),
                ?assertIsNode(Node1),
                Variables =
                    case get_total(Options) of
                        1 ->
                            ?assertNotMatch(
                                _ when is_list(VariableOrVariables), VariableOrVariables
                            ),
                            [VariableOrVariables];
                        Total ->
                            ?assertEqual(Total, length(VariableOrVariables)),
                            VariableOrVariables
                    end,
                lists:foreach(
                    fun(Variable) ->
                        ?assertNodeType(Variable, variable)
                    end,
                    Variables
                ),
                NewBindings = get_existing_bindings(Node1),
                Bindings = ordsets:subtract(NewBindings, ExistingBindings),
                ?assertMatch(_ when length(Bindings) =:= length(Variables), Bindings),
                ?assertEqual(
                    [],
                    ordsets:subtract(
                        Bindings,
                        ordsets:from_list(
                            lists:map(fun erl_syntax:variable_name/1, Variables)
                        )
                    )
                )
            end
        )
    }).

has_test_() ->
    Options = #{
        constraint_tries => 100
    },
    maps:to_list(#{
        "bindings" => ?_quickcheck(
            expression_with_annotated_bindings(),
            Expression,
            ?assert(has(Expression)),
            Options
        ),
        "no bindings" => ?_quickcheck(
            expression_type(),
            Expression,
            ?assertNot(has(Expression))
        ),
        "existing binding" => ?_quickcheck(
            expression_with_binding_type(),
            {Expression, Binding, BindingState},
            begin
                ?assert(has(Expression, Binding)),
                ?assert(has(Expression, Binding, BindingState))
            end,
            Options
        ),
        "missing binding" => ?_quickcheck(
            expression_with_annotated_bindings(),
            Expression,
            begin
                ?assertNot(has(Expression, "missing binding")),
                ?assertNot(has(Expression, "missing binding", env)),
                ?assertNot(has(Expression, "missing binding", bound)),
                ?assertNot(has(Expression, "missing binding", free))
            end,
            Options
        ),
        "broken bindings raises an assertion error" => fun() ->
            Variable0 = {var, ?LINE, 'Variable'},
            Variable1 = erl_syntax:set_ann(Variable0, [
                {env, not_an_ordset}, {bound, [sorted, badly]}, {free, #{"not" => "an ordset"}}
            ]),
            ?assertError({assert, _}, has(Variable1)),
            Variable2 = erl_syntax:add_ann({env, []}, Variable1),
            ?assertError({assert, _}, has(Variable2)),
            Variable3 = erl_syntax:add_ann({bound, []}, Variable2),
            ?assertError({assert, _}, has(Variable3)),
            Variable4 = erl_syntax:add_ann({free, []}, Variable3),
            %% All bindings are now valid
            ?assertNotException(error, {assert, _}, has(Variable4))
        end
    }).

get_by_state_test() ->
    ?quickcheck(
        {variables_type(), binding_state_type()},
        {Bindings, State},
        begin
            Expression0 = erl_syntax:variable('Foo'),
            Expression1 = erl_syntax:add_ann({State, Bindings}, Expression0),
            ?assertEqual(Bindings, get_by_state(Expression1, State))
        end
    ).

get_test_() ->
    [
        {"unbound", fun() ->
            Expression0 = erl_syntax:variable('Variable'),
            Expression1 = erl_syntax:set_ann(Expression0, [
                {env, []}, {bound, []}, {free, []}
            ]),
            ?assertEqual(unbound, get(Expression1, 'Foo'))
        end},
        ?_quickcheck(
            binding_state_type(),
            State,
            begin
                Expression0 = erl_syntax:variable('Variable'),
                Expression1 = erl_syntax:set_ann(Expression0, [
                    {env, []}, {bound, []}, {free, []}
                ]),
                Expression2 = erl_syntax:add_ann({State, ['Foo']}, Expression1),
                ?assertEqual(State, get(Expression2, 'Foo'))
            end
        )
    ].

%%%_ * PropEr Types ----------------------------------------------------------

-define(PROPER_ERLANG_OPTIONS, [
    {weight, {var, 25}},
    {weight, {pat_var, 50}},
    {weight, {varcall, 10}},
    {weight, {var_eclass, 10}},
    {weight, {var_timeout, 10}}
]).

module_forms_type() ->
    proper_erlang_abstract_code:module(?PROPER_ERLANG_OPTIONS).

variables_type() ->
    ?SUCHTHATMAYBE(
        Atoms,
        orderedlist(atom()),
        length(Atoms) =:= length(ordsets:from_list(Atoms))
    ).

binding_state_type() ->
    oneof([env, bound, free]).

expression_type() ->
    proper_erlang_abstract_code:expr(?PROPER_ERLANG_OPTIONS).

expression_with_annotated_bindings() ->
    ?LET(
        {Expression0, Format, Counter, Env},
        {expression_type(), format_option_type(), pos_integer_type(), variables_type()},
        begin
            Expression1 = erl_syntax:block_expr([
                erl_syntax:variable(
                    unicode:characters_to_list(
                        io_lib:format(Format, [Counter])
                    )
                ),
                Expression0
            ]),
            erl_syntax_lib:annotate_bindings(Expression1, Env)
        end
    ).

expression_with_binding_type() ->
    ?LET(
        {AnnotatedExpression0, Binding, State},
        {expression_with_annotated_bindings(), atom(), binding_state_type()},
        begin
            Annotations = erl_syntax:get_ann(AnnotatedExpression0),
            {State, Bindings0} = lists:keyfind(State, 1, Annotations),
            Bindings1 = ordsets:add_element(Binding, Bindings0),
            AnnotatedExpression1 = erl_syntax:add_ann(
                {State, Bindings1}, AnnotatedExpression0
            ),
            {AnnotatedExpression1, Binding, State}
        end
    ).

new_options_type() ->
    oneof([
        #{},
        pos_integer_type(),
        format_option_type(),
        ?LET(
            Options,
            [
                default(undefined, {file, file_option_type()}),
                default(undefined, {format, format_option_type()}),
                default(undefined, {location, location_option_type()}),
                default(undefined, {total, pos_integer_type()})
            ],
            maps:from_list([
                {Key, Value}
             || {Key, Value} <- Options
            ])
        )
    ]).

file_option_type() ->
    oneof([
        ?FILE,
        ?SUCHTHAT(File, non_empty(string()), string:find(File, "\0") =:= nomatch)
    ]).

format_option_type() ->
    oneof([
        %% Matches variables generated by proper_erlang_abstract_code
        "V~tp",
        %% Default format
        "var-~tp",
        %% Some (assumed) common formats
        "Var~tp",
        "Arg~tp",
        "Var@~tp",
        "Arg@~tp",
        %% Elixir uses lowercase, so let's test those as well
        "var~tp",
        "arg~tp",
        "var@~tp",
        "arg@~tp"
    ]).

location_option_type() ->
    oneof([
        nat(),
        {nat(), pos_integer_type()}
    ]).

pos_integer_type() ->
    ?SIZED(Size, integer(1, max(1, Size))).

get_existing_bindings(Node) ->
    Annotations = erl_syntax:get_ann(Node),
    ExistingBindings = ordsets:union([
        element(2, {env, _} = lists:keyfind(env, 1, Annotations)),
        element(2, {bound, _} = lists:keyfind(bound, 1, Annotations)),
        element(2, {free, _} = lists:keyfind(free, 1, Annotations))
    ]),
    ExistingBindings.

get_total(Total) when is_integer(Total) ->
    Total;
get_total(#{total := Total}) when is_integer(Total) ->
    Total;
get_total(_) ->
    1.

missing_bindings(Bindings, Variables) ->
    ordsets:subtract(
        Bindings,
        ordsets:from_list(lists:map(fun erl_syntax:variable_name/1, Variables))
    ).

-endif.
