%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Parse transform helper library
%%%
%%% The main function is {@link transform/3}, which let's you easily traverse
%%% an {@link ast()}, optionally modify it, and carry a state.
%%%
%%% There are a few {@link merlin_module:annotate/2. helper} &#0160;
%%% {@link merlin_module:analyze/1. functions} that provides easy access to
%%% commonly needed information. For example the current set of
%%% {@link erl_syntax_lib:annotate_bindings/2. bindings} and the
%%% <abbr title="Module:Function/Arity">MFA</abbr> for every
%%% {@link erl_syntax:application/2. function call}.
%%%
%%% Finally, when you're done transforming {@link return/1} the result in the
%%% format expected by {@link erl_lint} (or else you crash the compiler).
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%_* Module declaration =====================================================
-module(merlin).

%%%_* Exports ================================================================
%%%_ * API -------------------------------------------------------------------
-export([
    transform/3,
    revert/1,
    return/1
]).

%%%_* Types ------------------------------------------------------------------
%% Syntax tree types
-export_type([
    ast/0,
    erl_parse/0,
    erl_syntax_ast/0,
    error_marker/0,
    warning_marker/0
]).

%% `transform/3' related types
-export_type([
    action/0,
    phase/0,
    transformer/0,
    transformer/1,
    transformer_return/1
]).

%% Parse transform types, defined here because there's no `parse_transform'
%% behaviour.
-export_type([
    exceptions_grouped_by_file/0,
    parse_transform_return/0,
    parse_transform_return/1
]).

%%%_* Includes ===============================================================
-include("internal.hrl").
-include("assertions.hrl").
-include("log.hrl").

-ifdef(TEST).
-define(PROPER_NO_IMPORTS, true).
-include("merlin_test.hrl").
-endif.

%%%_* Macros =================================================================

%%%_* Types ==================================================================
-record(state, {
    file :: string(),
    module :: module(),
    transformer :: transformer(TransformerState),
    transformer_state :: TransformerState,
    errors = [] :: [error_marker()],
    warnings = [] :: [warning_marker()],
    depth = 0 :: integer()
}).

-type error_marker() :: {error, marker_with_file()}.
%% Represents a compile time error. Must match {@link erl_lint:error_info()}.

-type warning_marker() :: {warning, marker_with_file()}.
%% Represents a compile time warning. Must match {@link erl_lint:error_info()}.

-type marker_with_file() :: {File :: file:filename(), erl_lint:error_info()}.

-type parse_transform_return() ::
    parse_transform_return([ast()]).

-type parse_transform_return(Forms) ::
    Forms
    | {warning, Forms, exceptions_grouped_by_file()}
    | {error, exceptions_grouped_by_file(), exceptions_grouped_by_file()}.
%% Represents the return value from a parse transform. Defined here because
%% there's no `parse_transform' behaviour.

-type exceptions_grouped_by_file() ::
    [{File :: string(), [erl_lint:error_info()]}].

-type transformer() :: transformer(State :: term()).

-type transformer(State) :: fun((phase(), ast(), State) -> transformer_return(State)).
%% Represents the callback used by {@link transform/3}.

-type phase() :: enter | leaf | exit.
%% Represents the direction of the depth-first traversal through the
%% {@link ast()}.
%%
%% @see transformer/3

-type ast() ::
    erl_syntax_ast()
    | erl_parse()
    | erl_syntax:syntaxTree()
    | {eof, erl_anno:anno()}.
%% Represents a syntax tree node. May be a tree or a leaf.

-type node_or_nodes() :: ast() | [ast()].

-type erl_syntax_ast() ::
    {tree, Type :: atom(), erl_syntax:syntaxTreeAttributes(), Data :: term()}
    | {wrapper, Type :: atom(), erl_syntax:syntaxTreeAttributes(), Tree :: erl_parse()}.
%% A bit dirty to know about the internal structure like this, but
%% {@link erl_syntax:syntaxTree()} also includes the vanilla AST and dialyser
%% doesn't always approve of that.

-type erl_parse() ::
    erl_parse:abstract_clause()
    | erl_parse:abstract_expr()
    | erl_parse:abstract_form()
    | erl_parse:abstract_type()
    | erl_parse:form_info()
    | erl_parse:af_binelement(term())
    | erl_parse:af_generator()
    | erl_parse:af_remote_function().
%% Copied from erl_syntax

-type action() :: continue | delete | return | exceptions.
%% Represents the action to take after calling the {@link transformer()}
%% callback.
%%
%% <dl>
%% <dt>`continue'</dt>
%% <dd>means to continue traversing the {@link ast()}.</dd>
%% <dt>`delete'</dt>
%% <dd>means to delete the current node from the {@link ast()}.</dd>
%% <dt>`return'</dt>
%% <dd>means to stop traversing the {@link ast()} and return the current
%%     node.</dd>
%% <dt>`exceptions'</dt>
%% <dd>means to stop traversing the {@link ast()} and return the given
%%     exceptions.</dd>
%% </dl>

-type transformer_return(State) ::
    node_or_nodes()
    | {node_or_nodes(), State}
    | continue
    | {continue, node_or_nodes()}
    | {continue, node_or_nodes(), State}
    | return
    | {return, node_or_nodes()}
    | {return, node_or_nodes(), State}
    | delete
    | {delete, State}
    | {error, Reason :: term()}
    | {error, Reason :: term(), State}
    | {warning, Reason :: term()}
    | {warning, Reason :: term(), node_or_nodes()}
    | {warning, Reason :: term(), node_or_nodes(), State}
    | {exceptions, [{error | warning, Reason :: term()}]}
    | {exceptions, [{error | warning, Reason :: term()}], node_or_nodes()}
    | {exceptions, [{error | warning, Reason :: term()}], node_or_nodes(), State}.
%% Represents the return value from the {@link transformer()} callback.
%%
%% The first element is the {@link action()}, the second the new or
%% modified node or nodes, and the third the new state.
%%
%% Returning an atom is a shorthand for reusing the current node and state.
%% Returning a two-tuple is a shorthand for reusing the current state.
%%
%% You may also return `{error, Reason} | {warning, Reason}' to generate a
%% compile time warning. These will be propagated to `erl_lint'. To generate
%% multiple warnings, return `{exceptions, ListOfErrorsAndWarnings}'.

%%%_* Code ===================================================================
%%%_ * API -------------------------------------------------------------------

%% @doc Transforms the given `Forms' using the given `Transformer' with the
%% given `State'.
%%
%% This is done thorugh a depth-first traversal of the given `Forms'.
%%
%% <ul>
%% <li>First `enter'ing each tree node (top-down)</li>
%% <li>Then, when you encounter a `leaf' node, you both "enter" and "exit" the node</li>
%% <li>Finally `exit'ing each tree node (bottom-up)</li>
%% </ul>
%%
%% For example, if you just want to change a call to a specific function, you
%% would just use the top-down `enter' phase.
%%
%% ```
%% parse_transform(Forms, _Options) ->
%%    transform(
%%        Forms,
%%        fun (enter, Form, _State) ->
%%                case erl_syntax:type(Form) of
%%                    %% Application is the name of a function call
%%                    application ->
%%                        Operator erl_syntax:application_operator(Form),
%%                        case erl_syntax:type(Operator) =:= atom andalso
%%                             erl_syntax:atom_value(Operator) =:= foo of
%%                           true ->
%%                                %% Change `foo(...)' to `my_module:foo(...)'
%%                                %% using `merl' or `merlin_quote_transform'
%%                                {return, ?Q("my_module:foo(123)")};
%%                          false ->
%%                               continue
%%                       end;
%%                    _ ->
%%                        continue
%%                 end;
%%            (_, _, _) ->
%%                continue
%%         end,
%%        state
%%   ).
%% '''
%%
%% Sometimes it is easier, or necessary, to use a bottom-up approach. You can
%% use `exit' for that. Sometimes you need both, and here is where `merlin'
%% really shines, as you can just pattern match of `enter' and `exit' in the
%% same function.
%%
%% The latter shows up when you want to do some analysis on the way down, and
%% then use that information on the way up.
%%
%% For a real world example see {@link merlin_quote_transform}. That one is
%% also pretty handy for writing {@link transformer(). transformers}.
-spec transform(Forms, transformer(State), State) ->
    {parse_transform_return(Forms), State}
when
    Forms :: [ast()].
transform(Forms, Transformer, TransformerState) when
    is_list(Forms) andalso is_function(Transformer, 3)
->
    InternalState0 = #state{
        file = merlin_module:file(Forms),
        module = merlin_module:name(Forms),
        transformer = Transformer,
        transformer_state = TransformerState
    },
    set_logger_target(InternalState0),
    ?notice(
        "Transforming using ~s:~s/~p",
        tuple_to_list(merlin_internal:fun_to_mfa(Transformer))
    ),
    ?show(Forms),
    {Forms1, InternalState1} =
        try
            transform_internal(Forms, InternalState0)
        catch
            throw:Reason:Stacktrace ->
                %% compile:foldl_transform/3 uses a `catch F(...)' when calling parse
                %% transforms. Unfortunately this means `throw'n errors turns into
                %% normal values.
                ?log_exception(throw, Reason, Stacktrace),
                erlang:raise(error, Reason, Stacktrace);
            Class:Reason:Stacktrace ->
                ?log_exception(Class, Reason, Stacktrace),
                erlang:raise(Class, Reason, Stacktrace)
        end,
    ?info("Final state ~tp", [InternalState1#state.transformer_state]),
    Forms2 = finalize(Forms1, InternalState1),
    ?show(Forms2),
    {Forms2, InternalState1#state.transformer_state}.

%% @doc Returns the result from {@link transform/3}, or just the
%% final forms, to an {@link erl_lint} compatible format.
%%
%% This {@link revert/1. reverts} the forms, while respecting any
%% errors and/or warnings.
-spec return(parse_transform_return(Forms) | {parse_transform_return(Forms), State}) ->
    parse_transform_return(Forms)
when
    State :: term(),
    Forms :: [ast()].
return({Result, _State}) ->
    _ = merlin_internal:write_log_file(),
    merlin_lib:then(Result, fun revert/1);
return(Result) ->
    _ = merlin_internal:write_log_file(),
    merlin_lib:then(Result, fun revert/1).

%% @doc Returns the given node or nodes in {@link erl_parse} format.
%%
%% Copied from `parse_trans:revert_form/1' and slightly modified. The original
%% also handles a bug in R16B03, but that is ancient history now.
revert(Nodes) when is_list(Nodes) ->
    lists:map(fun revert/1, Nodes);
revert(Node) ->
    case erl_syntax:revert(Node) of
        {attribute, Line, Arguments, ErlSyntaxTree} when
            element(1, ErlSyntaxTree) == tree
        ->
            {attribute, Line, Arguments, revert(ErlSyntaxTree)};
        ErlParseNode ->
            ErlParseNode
    end.

%%%_* Private ----------------------------------------------------------------
%%% Start transform helpers

%% @private
-spec transform_internal
    (Node, #state{}) -> {Node, #state{}} when
        Node :: ast();
    (Forms, #state{}) -> {Forms, #state{}} when
        Forms :: [ast()].
transform_internal(Forms0, State0) when is_list(Forms0) ->
    {Forms1, State1} = lists:mapfoldl(fun transform_internal/2, State0, Forms0),
    {lists:flatten(Forms1), State1};
transform_internal(Form, State0) ->
    set_target_mfa(Form, State0),
    State1 = update_file(Form, State0),
    case form_kind(Form) of
        leaf ->
            {_Action, Node1, State2} = call_transformer(leaf, Form, State1),
            %% Here, at the leaf node, the action does not matter, as we're not
            %% recursing anymore.
            {Node1, State2};
        form_list ->
            Forms0 = erl_syntax:flatten_form_list(Form),
            Forms1 = erl_syntax:form_list_elements(Forms0),
            transform_internal(Forms1, State0);
        _ ->
            {Action0, Tree1, State2} = call_transformer(enter, Form, State1),
            case Action0 of
                continue ->
                    State3 = increment_depth(State2),
                    {Tree2, State4} = mapfold_subtrees(
                        fun transform_internal/2,
                        State3,
                        Tree1
                    ),
                    State5 = decrement_depth(State4),
                    {_Action1, Tree3, State6} = call_transformer(
                        exit,
                        Tree2,
                        State5
                    ),
                    %% Like with the leaf node, we're not recursing here so
                    %% just return whatever result we've got.
                    {Tree3, State6};
                return ->
                    {Tree1, State2}
            end
    end.

%% @private
form_kind(Form) ->
    case erl_syntax:is_leaf(Form) of
        true ->
            leaf;
        false ->
            erl_syntax:type(Form)
    end.

%% @private
-spec mapfold_subtrees(Fun, #state{}, ast()) -> {ast(), #state{}} when
    Fun :: fun((ast(), #state{}) -> {ast(), #state{}}).
mapfold_subtrees(Fun, State0, Tree0) ->
    case erl_syntax:subtrees(Tree0) of
        [] ->
            {Tree0, State0};
        Groups0 ->
            {Groups1, State1} = erl_syntax_lib:mapfoldl_listlist(
                Fun,
                State0,
                Groups0
            ),
            Groups2 = lists:map(fun lists:flatten/1, Groups1),
            Tree1 = erl_syntax:update_tree(Tree0, Groups2),
            {Tree1, State1}
    end.

%% @private
%% @doc Calls the user transformer and heavily normalizes its return value.
%%
%% The transformer may return many different tuples prefixed with 5
%% different actions. This reduces that to just 2 actions and folds the
%% returned updated nodes/errors/warnings into our internal state.
-spec call_transformer(phase(), ast(), #state{}) -> {Action, Tree, #state{}} when
    Action :: continue | return,
    %% erl_syntax:form_list
    Tree :: ast().
call_transformer(
    Phase,
    Node0,
    #state{
        transformer = Transformer,
        transformer_state = TransformerState0,
        errors = ExistingErrors,
        warnings = ExistingWarnings
    } = State0
) ->
    set_logger_target(line, erl_syntax:get_pos(Node0)),
    set_logger_target(state, TransformerState0),
    {Action, NodeOrNodes0, TransformerState1, Reasons} = expand_callback_return(
        Transformer(Phase, Node0, TransformerState0),
        Node0,
        TransformerState0
    ),
    NodeOrNodes1 =
        case merlin_lib:flatten(NodeOrNodes0) of
            [Node1] -> Node1;
            Nodes -> Nodes
        end,
    log_call_transformer(
        Phase, Node0, TransformerState0, Action, NodeOrNodes1, TransformerState1
    ),
    State1 = State0#state{transformer_state = TransformerState1},
    {FirstNode, {TransformerStateErrors, TransformerStateWarnings}} =
        case NodeOrNodes1 of
            [Head | _] ->
                TransformerStateReasons = lists:filter(
                    fun is_error_or_warning/1, NodeOrNodes1
                ),
                {Head, format_markers(TransformerStateReasons, Head, State1)};
            _ ->
                {NodeOrNodes1, {[], []}}
        end,
    {Errors, Warnings} = format_markers(Reasons, FirstNode, State1),
    State2 = State1#state{
        errors = Errors ++ TransformerStateErrors ++ ExistingErrors,
        warnings = Warnings ++ TransformerStateWarnings ++ ExistingWarnings
    },
    case Action of
        _ when length(Errors) + length(TransformerStateErrors) > 0 ->
            {return, NodeOrNodes1, State2};
        exceptions ->
            {continue, NodeOrNodes1, State2};
        delete ->
            {return, [], State2};
        continue ->
            {continue, NodeOrNodes1, State2};
        return ->
            {return, NodeOrNodes1, State2}
    end.

is_error_or_warning({error, _}) -> true;
is_error_or_warning({warning, _}) -> true;
is_error_or_warning(_) -> false.

%% @private
%% @doc Normalizes the return value from the user transformar into a
%% consistent 4-tuple.
%%
%% This makes the {@link call_transformer/3} much simpler to write.
-spec expand_callback_return(Return, Node, TransformerState) ->
    {action(), node_or_nodes(), TransformerState, Exceptions}
when
    Return ::
        continue
        | delete
        | return
        | {continue | return, node_or_nodes()}
        | {continue | return, node_or_nodes(), TransformerState}
        | {error | warning, Reason}
        | {error, Reason, TransformerState}
        | {warning, Reason, node_or_nodes()}
        | {warning, Reason, node_or_nodes(), TransformerState}
        | {exceptions, Exceptions}
        | {exceptions, Exceptions, node_or_nodes()}
        | {exceptions, Exceptions, node_or_nodes(), TransformerState}
        | {node_or_nodes(), TransformerState}
        | node_or_nodes(),
    Node :: ast(),
    TransformerState :: term(),
    Reason :: term(),
    Exceptions :: [{error, Reason} | {warning, Reason}].
expand_callback_return(Action, Node0, TransformerState0) when
    ?oneof(Action, continue, return, delete)
->
    {Action, Node0, TransformerState0, []};
expand_callback_return({Action, Reason}, Node0, TransformerState0) when
    ?oneof(Action, error, warning)
->
    {exceptions, Node0, TransformerState0, [{Action, Reason}]};
expand_callback_return({error, Reason, TransformerState1}, Node0, _TransformerState0) ->
    {exceptions, Node0, TransformerState1, [{error, Reason}]};
expand_callback_return({warning, Reason, Node1}, _Node0, TransformerState0) ->
    {exceptions, Node1, TransformerState0, [{warning, Reason}]};
expand_callback_return(
    {warning, Reason, Node1, TransformerState1}, _Node0, _TransformerState0
) ->
    {exceptions, Node1, TransformerState1, [{warning, Reason}]};
expand_callback_return({exceptions, Exceptions}, Node0, TransformerState0) ->
    {exceptions, Node0, TransformerState0, Exceptions};
expand_callback_return({exceptions, Exceptions, Node1}, _Node0, TransformerState0) ->
    {exceptions, Node1, TransformerState0, Exceptions};
expand_callback_return(
    {exceptions, Exceptions, Node1, TransformerState1}, _Node0, _TransformerState0
) ->
    {exceptions, Node1, TransformerState1, Exceptions};
expand_callback_return({delete, TransformerState1}, Node0, _TransformerState0) ->
    {delete, Node0, TransformerState1, []};
expand_callback_return({return, Node1}, _Node0, TransformerState0) ->
    {return, Node1, TransformerState0, []};
expand_callback_return({return, Node1, TransformerState1}, _Node0, _TransformerState0) ->
    {return, Node1, TransformerState1, []};
expand_callback_return(
    {parse_transform, Forms, TransformerState1}, _Node0, _TransformerState0
) ->
    {return, Forms, TransformerState1, []};
expand_callback_return({continue, Node1}, _Node0, TransformerState0) ->
    {continue, Node1, TransformerState0, []};
expand_callback_return(
    {continue, Node1, TransformerState1}, _Node0, _TransformerState0
) ->
    {continue, Node1, TransformerState1, []};
expand_callback_return({Node1, TransformerState1}, _Node0, _TransformerState0) when
    is_tuple(Node1)
->
    {continue, Node1, TransformerState1, []};
expand_callback_return(Nodes, _Node0, TransformerState0) when is_list(Nodes) ->
    {continue, Nodes, TransformerState0, []};
expand_callback_return(Node1, _Node0, TransformerState0) ->
    case check_syntax(Node1) of
        form_list ->
            {continue, Node1, TransformerState0, []};
        {error, Reason} ->
            {return, Node1, TransformerState0, [{error, Reason}]};
        _ ->
            {continue, Node1, TransformerState0, []}
    end.

check_syntax(Node) ->
    try
        erl_syntax:type(Node)
    catch
        error:{badarg, _} ->
            {error, "bad syntax"}
    end.

%% @private
-spec format_markers([term()], ast(), #state{}) -> {Errors, Warnings} when
    Errors :: [error_marker()],
    Warnings :: [warning_marker()].
format_markers(Reasons, Node, State) ->
    lists:partition(
        fun({Type, _}) ->
            Type == error
        end,
        [
            format_marker(Type, Reason, Node, State)
         || {Type, Reason} <- Reasons
        ]
    ).

%% @private
-spec format_marker
    (error, term(), ast(), #state{}) -> error_marker();
    (warning, term(), ast(), #state{}) -> warning_marker().
format_marker(
    Type,
    {File, {Position, FormattingModule, _Reason} = Marker},
    _Node,
    #state{} = State
) when
    (Type == error orelse Type == warning) andalso
        (File == [] orelse is_integer(hd(File))) andalso
        (is_integer(Position) orelse is_integer(element(1, Position)) orelse
            is_list(Position)) andalso
        is_atom(FormattingModule)
->
    case File of
        [] ->
            %% Rebar crashes on empty `file'
            {Type, {State#state.file, Marker}};
        _ ->
            {Type, Marker}
    end;
format_marker(Type, Reason, Node, #state{
    file = File,
    transformer = Transformer
}) ->
    {module, Module} = erlang:fun_info(Transformer, module),
    Position = erl_syntax:get_pos(Node),
    FormattingModule =
        case erlang:function_exported(Module, format_error, 1) of
            true -> Module;
            false -> merlin_error
        end,
    {Type, {File, {Position, FormattingModule, Reason}}}.

%% @private
%% @doc Returns the result of {@link transform_internal/2} as expected by
%% {@link erl_lint}.
%%
%% However, the returned forms are in {@link erl_syntax} format and must be
%% {@link revert/1. reverted} before returning from a parse_transform. You can
%% use {@link return/1} for that.
%%
%% This matches the `case' in {@link compile:foldl_transform/3}.
finalize(Tree, #state{errors = [], warnings = []}) ->
    Tree;
finalize(Tree, #state{errors = [], warnings = Warnings}) ->
    {warning, Tree, group_by_file(Warnings)};
finalize(_Tree, #state{errors = Errors, warnings = Warnings}) ->
    {error, group_by_file(Errors), group_by_file(Warnings)}.

%% @private
-spec group_by_file(Exceptions) -> [{File :: string(), [erl_lint:error_info()]}] when
    Exceptions :: [error_marker() | warning_marker() | marker_with_file()].
group_by_file(Exceptions) ->
    maps:to_list(lists:foldl(fun group_by_file/2, #{}, Exceptions)).

%% @private
-spec group_by_file(Exception, Files) -> Files when
    Exception :: error_marker() | warning_marker() | marker_with_file(),
    Files :: #{File => [erl_lint:error_info()]},
    File :: string().
group_by_file(
    {Type, {File, {Position, FormattingModule, _Reason}} = Marker},
    Files
) when
    (Type == error orelse Type == warning) andalso
        (File == [] orelse is_integer(hd(File))) andalso
        (is_integer(Position) orelse is_integer(element(1, Position))) andalso
        is_atom(FormattingModule)
->
    group_by_file(Marker, Files);
group_by_file({File, Marker}, Files) ->
    Markers = maps:get(File, Files, []),
    Files#{
        File => [Marker | Markers]
    }.

%% Logger helpers

%% @private
log_call_transformer(
    Phase, NodeIn, TransformerStateIn, Action, NodeOrNodes, TransformerStateOut
) ->
    NodeOut =
        case NodeOrNodes of
            [Head | _] -> Head;
            _ -> NodeOrNodes
        end,
    set_logger_target(line, erl_syntax:get_pos(NodeOut)),
    set_logger_target(state, TransformerStateOut),
    ?info(
        if
            is_list(NodeOrNodes) -> "~s ~s -> ~s [~s, ...]";
            true -> "~s ~s -> ~s ~s"
        end,
        [Phase, erl_syntax:type(NodeIn), Action, erl_syntax:type(NodeOut)]
    ),
    ?debug(
        lists:flatten(
            lists:join($\n, [
                "NodeIn = ~s",
                "TransformerStateIn = ~tp",
                "NodeOrNodes = ~s",
                "TransformerStateOut = ~tp"
            ])
        ),
        [
            merlin_internal:format(NodeIn),
            TransformerStateIn,
            merlin_internal:format(NodeOrNodes),
            TransformerStateOut
        ]
    ),
    %% Silence unused variable  warning if the logging above is disabled
    _ = Phase,
    _ = NodeIn,
    _ = TransformerStateIn,
    _ = Action,
    ok.

%% @private
update_file(Form, State) ->
    case merlin_internal:maybe_get_file_attribute(Form) of
        false ->
            State;
        NewFile ->
            ?info("Changing file ~s", [NewFile]),
            set_logger_target(file, NewFile),
            State#state{file = NewFile}
    end.

%% @private
set_target_mfa(Node, #state{module = Module}) ->
    case erl_syntax:type(Node) of
        function ->
            Name = merlin_lib:value(erl_syntax:function_name(Node)),
            Arity = erl_syntax:function_arity(Node),
            set_logger_target(mfa, {Module, Name, Arity});
        _ ->
            ok
    end.

%% @private
increment_depth(#state{depth = Depth} = State) ->
    set_logger_target(indent, lists:duplicate(Depth + 1, "    ")),
    State#state{depth = Depth + 1}.

%% @private
decrement_depth(#state{depth = 1} = State) ->
    unset_logger_target(indent),
    State#state{depth = 0};
decrement_depth(#state{depth = Depth} = State) ->
    set_logger_target(indent, lists:duplicate(Depth - 1, "    ")),
    State#state{depth = Depth - 1}.

%% @private
get_logger_target() ->
    Default = #{line => none},
    case logger:get_process_metadata() of
        undefined -> Default;
        Metadata -> maps:get(target, Metadata, Default)
    end.

%% @private
set_logger_target(#state{file = File, module = Module, transformer = Transformer}) ->
    MFA = merlin_internal:fun_to_mfa(Transformer),
    logger:update_process_metadata(#{
        target => maps:merge(get_logger_target(), #{
            file => File,
            module => Module,
            transformer => MFA
        })
    }).

%% @private
set_logger_target(Key, Value) ->
    logger:update_process_metadata(#{
        target => maps:put(Key, Value, get_logger_target())
    }).

%% @private
unset_logger_target(Key) ->
    logger:update_process_metadata(#{
        target => maps:remove(Key, get_logger_target())
    }).

%%%_* Tests ==================================================================
-ifdef(TEST).

examples_test_() ->
    [
        {filename:basename(Example), fun() ->
            PreProcessedResult = epp:parse_file(Example, ["include"], []),
            ?assertMatch({ok, _}, PreProcessedResult),
            {ok, ModuleForms} = PreProcessedResult,
            {_Analysis, Options} = merlin_module:analyze(ModuleForms, []),
            ParseTransforms = proplists:get_all_values(parse_transform, Options),
            TransformedForms = lists:foldl(
                fun(ParseTransform, Forms) ->
                    ParseTransform:parse_transform(Forms, Options)
                end,
                ModuleForms,
                ParseTransforms
            ),
            ?pp(TransformedForms),
            ?assertMatch(
                {ok, Module, Beam} when is_atom(Module) andalso is_binary(Beam),
                compile:forms(TransformedForms, [])
            )
        end}
     || Example <- filelib:wildcard("examples/*.erl")
    ].

smoke_test() ->
    ?quickcheck(
        {module_forms_type(), annotate_options_type()},
        {ModuleForms, Options},
        ?WHENFAIL(
            begin
                io:format("ModuleForms:\n~ts\n", [
                    merlin_internal:format(ModuleForms, #{
                        filename => ?FILE, line => ?LINE
                    })
                ])
            end,
            ?assertMerlEqual(ModuleForms, identity_transform(ModuleForms, Options))
        )
    ).

module_forms_type() ->
    ?LET(
        {ModuleForms, MaybeCompileAttribute},
        {
            proper_erlang_abstract_code:module(),
            proper_types:oneof([
                undefined,
                merl:quote(?LINE, "-compile({no_auto_import, [get/1]})."),
                merl:quote(?LINE, "-compile([export_all, nowarn_export_all]).")
            ])
        },
        case MaybeCompileAttribute of
            undefined -> ModuleForms;
            _ -> [MaybeCompileAttribute | ModuleForms]
        end
    ).

annotate_options_type() ->
    %% Ensure this stays in sync the available options for merlin_module:annotate/2
    ?LET(
        Options,
        [
            proper_types:default(undefined, bindings),
            proper_types:default(undefined, file),
            proper_types:default(undefined, resolve_calls),
            proper_types:default(undefined, resolve_types),
            proper_types:default(undefined, {compile, []})
        ],
        [Option || Option <- Options, Option =/= undefined]
    ).

identity_transform(Forms0, Options) ->
    Forms1 =
        case Options of
            [] -> merlin_module:annotate(Forms0);
            _ -> merlin_module:annotate(Forms0, Options)
        end,
    %% We do this just to increase code coverage
    Forms2 = [erl_syntax:form_list(Forms1)],
    return(transform(Forms2, fun identity_transformer/3, state)).

identity_transformer(enter, Node, _) ->
    case erl_syntax:is_literal(Node) of
        true ->
            %% Similarly here, this increaces code coverage while not actually
            %% changing anything.
            {continue, erl_syntax:form_list([Node])};
        false ->
            continue
    end;
identity_transformer(_, _, _) ->
    continue.

-endif.
