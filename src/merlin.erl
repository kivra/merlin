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
    annotate/1,
    annotate/2,
    analyze/1,
    analyze/2,
    find_form/2,
    find_forms/2,
    transform/3,
    revert/1,
    return/1,
    then/2
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

-ifdef(TEST).
-define(PROPER_NO_IMPORTS, true).
-include_lib("proper/include/proper.hrl").
-endif.

%%%_* Macros =================================================================
-define(else, true).

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

-type marker_with_file() :: {File :: string(), erl_lint:error_info()}.

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

-type ast() :: erl_syntax_ast() | erl_parse() | erl_syntax:syntaxTree().
%% Represents a syntax tree node. May be a tree or a leaf.

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
    ast()
    | {ast(), State}
    | continue
    | {continue, ast()}
    | {continue, ast(), State}
    | return
    | {return, ast()}
    | {return, ast(), State}
    | delete
    | {delete, State}
    | {error, Reason :: term()}
    | {error, Reason :: term(), State}
    | {warning, Reason :: term()}
    | {warning, Reason :: term(), ast()}
    | {warning, Reason :: term(), ast(), State}
    | {exceptions, [{error | warning, Reason :: term()}], ast(), State}.
%% Represents the return value from the {@link transformer()} callback.
%%
%% The first element is the {@link action()}, the second the new or
%% modified node or nodes, and the third the new state.
%%
%% Returning an atom is a shorthand for reusing the current node and state.
%% Returning a two-tuple is a shorthand for reusing the current state.
%%
%% You may also return `{error, Reason} | {warning, Reason}' to generate a
%% compile time warning. These will be propagated to `erl_lint'. You may also
%% return a list of these errors and/or warnings.

-type analysis() :: #{
    attributes := #{
        spec => #{atom() => ast()},
        type => #{atom() => ast()},
        atom() => [ast()]
    },
    exports := [function_name()],
    file := string(),
    functions := [{atom(), arity()}],
    imports := #{module() => [function_name()]},
    module_imports := [module()],
    records := map(),
    errors | module | warnings => _
}.

-type function_name() :: atom() | {atom(), arity()} | {module(), atom()}.

%%%_* Code ===================================================================
%%%_ * API -------------------------------------------------------------------

%% @equiv annotate(ModuleForms, [bindings, resolve_calls, file])
-spec annotate([ast()]) -> parse_transform_return().
annotate(ModuleForms) ->
    annotate(ModuleForms, [bindings, resolve_calls, file]).

%% @doc Annotate the given module {@link ast(). forms} according to the given
%% options.
%%
%% It always annotates each function definition with a `is_exported'
%% {@link merlin_lib:get_annotation/2. annotation}.
%%
%% <dl>
%% <dt>`bindings'</dt>
%% <dd>See {@link erl_syntax_lib:annotate_bindings/2}</dd>
%% <dt>`resolve_calls'</dt>
%% <dd>Resolves local and remote calls according to the `-import' attributes,
%% if any. For all successfully resolved calls, this sets both a `module' and
%% `is_exported' {@link merlin_lib:get_annotation/2. annotation} on the
%% {@link erl_syntax:application/2. `application'} form.</dd>
%% <dt>`file'</dt>
%% <dd>Each form is annotated with the current file, as determined by the most
%% recent `-file' attribute.</dd>
%% </dl>
-spec annotate(ModuleForms, Options) -> parse_transform_return(ModuleForms) when
    ModuleForms :: [ast()],
    Options :: [Option | {Option, boolean()}],
    Option :: bindings | resolve_calls | file.
annotate(ModuleForms, Options) ->
    State = maps:merge(maps:from_list(proplists:unfold(Options)), #{
        analysis => analyze(ModuleForms)
    }),
    {Result, #{analysis := Analysis}} = transform(
        ModuleForms,
        fun annotate_internal/3,
        State
    ),
    then(Result, fun(Forms) ->
        [
            case
                erl_syntax:type(Form) =:= attribute andalso
                    merlin_lib:value(erl_syntax:attribute_name(Form)) =:= module
            of
                true ->
                    merlin_lib:set_annotation(Form, analysis, Analysis);
                false ->
                    Form
            end
         || Form <- Forms
        ]
    end).

%% @doc Like `erl_syntax_lib:analyze_forms' but returns maps.
%%
%% Also all fields are present, except `module' so you can determine if it
%% exists or not. It also includes a `file' field and makes some fields
%% easier to use, like records being a map from name to definition.
%%
%% @see analysis()
-spec analyze([ast()]) -> analysis().
analyze(ModuleForms) ->
    Analysis = maps:from_list(erl_syntax_lib:analyze_forms(ModuleForms)),
    Analysis#{
        %% `module' is taken from Analysis if defined
        exports => maps:get(exports, Analysis, []),
        functions => maps:get(functions, Analysis, []),
        imports => get_as_map(Analysis, imports),
        attributes => attribute_map(Analysis),
        %% Seems unused, at least the docs does not mention carte blanc `-import'
        module_imports => maps:get(module_imports, Analysis, []),
        records => maps:map(
            fun record_fields_as_map/2,
            get_as_map(Analysis, records)
        ),

        %% Not part of the original, but so useful to have
        file => merlin_lib:file(ModuleForms)
    }.

%% @doc Same as {@link analyze/1}, but also extracts and appends any inline
%% `-compile' options to the given one.
-spec analyze([ast()], [compile:option()]) -> {analysis(), [compile:option()]}.
analyze(ModuleForms, Options) ->
    Analysis = analyze(ModuleForms),
    CombinedOptions =
        case Analysis of
            #{attributes := #{compile := InlineOptions}} ->
                Options ++ lists:flatten(InlineOptions);
            _ ->
                Options
        end,
    {Analysis, CombinedOptions}.

%% @doc Returns the first form for which the given function returns true.
%% This returns a `{ok, Form}' tuple on success, and `{error, notfound}'
%% otherwise.
find_form(Forms, Fun) when is_function(Fun, 1) ->
    try transform(Forms, fun find_form_transformer/3, Fun) of
        _ -> {error, notfound}
    catch
        %% Use the `fun' in the pattern to make it less likely to accidentally
        %% catch something.
        error:{found, Fun, Form} -> {ok, Form}
    end.

%% @doc Returns a flat list with all forms for which the given function
%% returns true, if any. They are returned in source order.
find_forms(Forms, Fun) when is_function(Fun, 1) ->
    {_, #{result := Result}} = transform(
        Forms,
        fun find_forms_transformer/3,
        #{filter => Fun, result => []}
    ),
    lists:reverse(Result).

%% @doc Calls the given function with the forms inside the given `Result',
%% while preserving any errors and/or warnings.
-spec then(Result, fun((Forms) -> Forms)) -> Result when
    Result :: parse_transform_return(Forms),
    Forms :: [ast()].
then({warning, Tree, Warnings}, Fun) when is_function(Fun, 1) ->
    {warning, Fun(Tree), Warnings};
then({error, Error, Warnings}, Fun) when is_function(Fun, 1) ->
    {error, Error, Warnings};
then(Tree, Fun) when is_function(Fun, 1) ->
    Fun(Tree).

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
transform(Forms, Transformer, TransformerState) when is_function(Transformer, 3) ->
    InternalState0 = #state{
        file = merlin_lib:file(Forms),
        module = merlin_lib:module(Forms),
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
    then(Result, fun revert/1);
return(Result) ->
    _ = merlin_internal:write_log_file(),
    then(Result, fun revert/1).

%% @doc Returns the given node or nodes in {@link erl_parse} format.
%%
%% Copied from `parse_trans:revert_form/1' and slightly modified. The original
%% also handles a bug in R16B03, but that is ancient history now.
revert(Forms) when is_list(Forms) ->
    lists:map(fun revert/1, Forms);
revert(Form) ->
    case erl_syntax:revert(Form) of
        {attribute, Line, Arguments, Tree} when element(1, Tree) == tree ->
            {attribute, Line, Arguments, erl_syntax:revert(Tree)};
        Result ->
            Result
    end.

%%%_* Private ----------------------------------------------------------------
%%% Start annotate helpers

%% @private
annotate_internal(enter, Form0, #{analysis := Analysis0} = State0) ->
    Analysis1 =
        case maybe_get_file_attribute(Form0) of
            false -> Analysis0;
            NewFile -> Analysis0#{file => NewFile}
        end,
    State1 = State0#{analysis => Analysis1},
    Form1 =
        case State1 of
            #{file := true, analysis := #{file := File}} ->
                merlin_lib:set_annotation(Form0, file, File);
            _ ->
                Form0
        end,
    case annotate_form(erl_syntax:type(Form1), Form1, State1) of
        {error, _} = Form2 -> Form2;
        {warning, _} = Form2 -> Form2;
        Form2 -> {continue, Form2, State1}
    end;
annotate_internal(_, _, _) ->
    continue.

%% @private
maybe_get_file_attribute(Form) ->
    case erl_syntax:type(Form) of
        attribute ->
            case erl_syntax:atom_value(erl_syntax:attribute_name(Form)) of
                file ->
                    [Filename, _Line] = erl_syntax:attribute_arguments(Form),
                    erl_syntax:string_value(Filename);
                _ ->
                    false
            end;
        _ ->
            false
    end.

%% @private
annotate_form(application, Form, #{
    analysis := Analysis,
    resolve_calls := true
}) ->
    case resolve_application(Form, Analysis) of
        {ok, Module, Name, Arity} ->
            merlin_lib:set_annotations(Form, #{
                is_exported => is_exported(Name, Arity, Analysis),
                module => Module
            });
        dynamic ->
            %% Dynamic value, can't resolve
            Form;
        ErrorOrWarning ->
            ErrorOrWarning
    end;
annotate_form(function, Form0, #{
    bindings := Bindings,
    analysis := #{
        attributes := Attributes
    } = Analysis
}) ->
    Name = erl_syntax:atom_value(erl_syntax:function_name(Form0)),
    Arity = erl_syntax:function_arity(Form0),
    Form1 = merlin_lib:set_annotation(
        Form0, is_exported, is_exported(Name, Arity, Analysis)
    ),
    Form2 =
        case Attributes of
            #{spec := #{{Name, Arity} := Spec}} ->
                merlin_lib:set_annotation(Form0, spec, Spec);
            _ ->
                Form1
        end,
    if
        Bindings ->
            Env = merlin_lib:get_annotation(Form2, env, ordsets:new()),
            erl_syntax_lib:annotate_bindings(Form2, Env);
        ?else ->
            Form2
    end;
annotate_form(_, Form, _) ->
    Form.

%% @private
resolve_application(Node, Analysis) ->
    Operator = erl_syntax:application_operator(Node),
    case erl_syntax:type(Operator) of
        atom ->
            case resolve_application_internal(Node, Analysis) of
                {ok, Module} ->
                    Name = erl_syntax:atom_value(Operator),
                    Arity = length(erl_syntax:application_arguments(Node)),
                    {ok, Module, Name, Arity};
                dynamic ->
                    dynamic;
                ErrorOrWarning ->
                    ErrorOrWarning
            end;
        _ ->
            dynamic
    end.

%% @private
resolve_application_internal(Node, Analysis) ->
    Operator = erl_syntax:application_operator(Node),
    case erl_syntax:type(Operator) of
        module_qualifier ->
            resolve_remote_application(Operator);
        atom ->
            resolve_local_application(Node, Analysis);
        _ ->
            %% Dynamic value, can't resolve
            dynamic
    end.

%% @private
resolve_remote_application(Operator) ->
    Qualifier = erl_syntax:module_qualifier_argument(Operator),
    case erl_syntax:type(Qualifier) of
        atom ->
            CallModule = erl_syntax:atom_value(Qualifier),
            {ok, CallModule};
        _ ->
            %% Dynamic value, can't resolve
            dynamic
    end.

%% @private
resolve_local_application(
    Node,
    #{
        functions := Functions,
        imports := Imports
    } = Analysis
) ->
    Operator = erl_syntax:application_operator(Node),
    Name = erl_syntax:atom_value(Operator),
    Arity = length(erl_syntax:application_arguments(Node)),
    Function = {Name, Arity},
    case lists:member(Function, Functions) of
        true ->
            %% Function defined in this module
            case Analysis of
                #{module := CallModule} ->
                    {ok, CallModule};
                _ ->
                    {warning, "Missing -module, can't resolve local function calls"}
            end;
        false ->
            case
                [
                    CallModule
                 || {CallModule, ImportedFunctions} <- maps:to_list(Imports),
                    lists:member(Function, ImportedFunctions)
                ]
            of
                [CallModule] ->
                    {ok, CallModule};
                [] ->
                    %% Assume all other calls refer to builtin functions
                    %% Maybe add a sanity check for compile no_auto_import?
                    {ok, erlang};
                CallModules ->
                    ListPhrase = list_phrase(CallModules),
                    Message = lists:flatten(
                        io_lib:format(
                            "Overlapping -import for ~tp/~tp from ~s",
                            [Name, Arity, ListPhrase]
                        )
                    ),
                    {error, Message}
            end
    end.

%% @private
list_phrase(List) ->
    CommaSeperatedList = lists:join(", ", List),
    LastCommaReplacedWithAnd = string:replace(
        CommaSeperatedList,
        ", ",
        " and ",
        trailing
    ),
    lists:concat(LastCommaReplacedWithAnd).

%% @private
is_exported(Name, Arity, #{exports := Exports}) ->
    lists:member({Name, Arity}, Exports).

%%% Start analyze helpers

%% @private
get_as_map(Analysis, Key) ->
    maps:from_list(maps:get(Key, Analysis, [])).

%% @private
record_fields_as_map(_Key, Fields) ->
    maps:from_list(Fields).

%% @private
attribute_map(Analysis) when not is_map_key(attributes, Analysis) ->
    #{};
attribute_map(#{attributes := []}) ->
    #{};
attribute_map(#{attributes := Attributes}) ->
    Groups = lists:foldl(fun pair_grouper/2, #{}, Attributes),
    Groups#{
        spec => group_by_name(maps:get(spec, Groups, [])),
        type => group_by_name(maps:get(type, Groups, []))
    }.

%% @private
%% @doc Groups the list of variable length tuples by their first element.
group_by_name(Tuples) ->
    group_pairs([{element(1, Value), Value} || Value <- Tuples]).

%% @private
%% @doc Groups the given list of two-tuples into a map.
group_pairs(Pairs) ->
    lists:foldl(fun pair_grouper/2, #{}, Pairs).

%% @private
pair_grouper({Type, Value}, Groups) ->
    Values = maps:get(Type, Groups, []),
    maps:put(Type, [Value | Values], Groups).

%%% Start find_form helpers

%% @private
find_form_transformer(Phase, Form, Fun) when Phase =:= enter orelse Phase =:= leaf ->
    case Fun(Form) of
        true -> error({found, Fun, Form});
        false -> continue
    end;
find_form_transformer(_, _, _) ->
    continue.

%% @private
find_forms_transformer(Phase, Form, #{filter := Fun, result := Result} = State) when
    Phase =:= enter orelse Phase =:= leaf
->
    case Fun(Form) of
        true ->
            {continue, Form, State#{result := [Form | Result]}};
        false ->
            continue
    end;
find_forms_transformer(_, _, _) ->
    continue.

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
    {Action, NodeOrNodes, TransformerState1, Reasons} = expand_callback_return(
        Transformer(Phase, Node0, TransformerState0),
        Node0,
        TransformerState0
    ),
    log_call_transformer(
        Phase, Node0, TransformerState0, Action, NodeOrNodes, TransformerState1
    ),
    State1 = State0#state{transformer_state = TransformerState1},
    {FirstNode, {TransformerStateErrors, TransformerStateWarnings}} =
        case NodeOrNodes of
            [Head | _] ->
                TransformerStateReasons = lists:filter(
                    fun is_error_or_warning/1, NodeOrNodes
                ),
                {Head, format_markers(TransformerStateReasons, Head, State1)};
            _ ->
                {NodeOrNodes, {[], []}}
        end,
    {Errors, Warnings} = format_markers(Reasons, FirstNode, State1),
    State2 = State1#state{
        errors = Errors ++ TransformerStateErrors ++ ExistingErrors,
        warnings = Warnings ++ TransformerStateWarnings ++ ExistingWarnings
    },
    case Action of
        _ when length(Errors) + length(TransformerStateErrors) > 0 ->
            {return, NodeOrNodes, State2};
        exceptions ->
            {continue, NodeOrNodes, State2};
        delete ->
            {return, [], State2};
        continue ->
            {continue, NodeOrNodes, State2};
        return ->
            {return, NodeOrNodes, State2}
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
    {action(), NodeOrNodes, TransformerState, Exceptions}
when
    Return ::
        continue
        | delete
        | return
        | {continue | return, NodeOrNodes}
        | {continue | return, NodeOrNodes, TransformerState}
        | {error | warning, Reason}
        | {error, Reason, TransformerState}
        | {warning, Reason, NodeOrNodes}
        | {warning, Reason, NodeOrNodes, TransformerState}
        | {exceptions, Exceptions}
        | {exceptions, Exceptions, NodeOrNodes}
        | {exceptions, Exceptions, NodeOrNodes, TransformerState}
        | {action(), ast(), TransformerState, Exceptions}
        | {parse_transform, parse_transform_return()}
        | {NodeOrNodes, TransformerState}
        | NodeOrNodes,
    Node :: ast(),
    NodeOrNodes :: ast() | [ast()],
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
%% This is for transformer wrappers
expand_callback_return({Action, Node1, TransformerState1, Reasons}, _Node0, _TransformerState0) when
    ?oneof(Action, continue, return, delete, error, warning, exceptions)
->
    {Action, Node1, TransformerState1, Reasons};
%% This is for wrapping full blown parse transforms
expand_callback_return(
    {parse_transform, {warning, Forms, Warnings0}, TransformerState1},
    _Node0,
    _TransformerState0
) ->
    Warnings1 = ungroup_exceptions(warning, Warnings0),
    {exceptions, Forms, TransformerState1, Warnings1};
expand_callback_return(
    {parse_transform, {error, Errors0, Warnings0, TransformerState1}},
    Node0,
    _TransformerState0
) ->
    Errors1 = ungroup_exceptions(warning, Errors0),
    Warnings1 = ungroup_exceptions(warning, Warnings0),
    {exceptions, Node0, TransformerState1, Errors1 ++ Warnings1};
expand_callback_return({parse_transform, Forms, TransformerState1}, _Node0, _TransformerState0) ->
    {return, Forms, TransformerState1, []};
expand_callback_return(
    {continue, Node1, TransformerState1}, _Node0, _TransformerState0
) ->
    {continue, Node1, TransformerState1, []};
expand_callback_return({Node1, TransformerState1}, _Node0, _TransformerState0) when
    is_tuple(Node1)
->
    {continue, Node1, TransformerState1, []};
expand_callback_return(Nodes, _Node0, TransformerState0) when is_list(Nodes) ->
    {continue, merlin_lib:flatten(Nodes), TransformerState0, []};
expand_callback_return(Node1, _Node0, TransformerState0) ->
    case check_syntax(Node1) of
        form_list ->
            {continue, merlin_lib:flatten(Node1), TransformerState0, []};
        {error, Reason} ->
            {return, Node1, TransformerState0, [{error, Reason}]};
        _ ->
            {continue, Node1, TransformerState0, []}
    end.

%% @private
ungroup_exceptions(Type, Groups) ->
    [
        {Type, {File, Marker}}
     || {File, Markers} <- Groups,
        Marker <- Markers
    ].

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
        (is_integer(Position) orelse is_integer(element(1, Position))) andalso
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
            true ->
                Module;
            false ->
                merlin_lib
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
log_call_transformer(Phase, NodeIn, TransformerStateIn, Action, NodeOrNodes, TransformerStateOut) ->
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
            ?else -> "~s ~s -> ~s ~s"
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
    case maybe_get_file_attribute(Form) of
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
-include_lib("eunit/include/eunit.hrl").

examples_test_() ->
    [
        {filename:basename(Example), fun() ->
            PreProcessedResult = epp:parse_file(Example, ["include"], []),
            ?assertMatch({ok, _}, PreProcessedResult),
            {ok, ModuleForms} = PreProcessedResult,
            {_Analysis, Options} = analyze(ModuleForms, []),
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

proper_test() ->
    ?quickcheck(transform_prop()).

transform_prop() ->
    ?FORALL(
        ModuleForms,
        proper_erlang_abstract_code:module(),
        ?WHENFAIL(
            begin
                ?pp(ModuleForms)
            end,
            case merl:match(ModuleForms, identity_transform(ModuleForms)) of
                {ok, Variables} when is_list(Variables) ->
                    true;
                _ ->
                    false
            end
        )
    ).

identity_transform(Forms) ->
    return(transform(annotate(Forms), fun identity_transformer/3, state)).

identity_transformer(_, _, _) -> continue.

-endif.
