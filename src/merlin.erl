-module(merlin).

-include("log.hrl").

-export([
    annotate/1,
    annotate/2,
    analyze/1,
    analyze/2,
    transform/3,
    revert/1,
    return/1
]).

-export_type([
    action/0,
    ast/0,
    error_marker/0,
    phase/0,
    transformer/1,
    transformer_return/1
]).

-define(else, true).


-record(state, {
    file :: string(),
    module :: module(),
    transformer :: transformer(Extra),
    extra :: Extra,
    errors = [] :: [error_marker()],
    warnings = [] :: [warning_marker()],
    depth = 0 :: integer()
}).

-type error_marker() :: exception_marker(error).
-type warning_marker() :: exception_marker(warning).

%% {Type, {File, {Position, Module, Reason}}}.
-type exception_marker(Type) :: { Type, marker() }.

-type marker() ::
    { File :: string(),
        { Position :: erl_anno:location()
        , Module :: module()
        , Reason :: term()
        }
    }.

-type phase() :: enter | leaf | exit.

-type ast() :: erl_syntax:syntaxTree().

-type action() :: continue | delete | return | exceptions.

-type transformer_return(Extra) ::
    ast() | {ast(), Extra} |
    continue | {continue, ast()} | {continue, ast(), Extra} |
    return   | {return,   ast()} | {return,   ast(), Extra} |
    delete   | {delete,   Extra} |
    {error,   term()} | {error,   term(), Extra} |
    {warning, term()} | {warning, term(), ast()} | {warning, term(), ast(), Extra} |
    {exceptions, [{error | warning, term()}], ast(), Extra}.

-type transformer(Extra) :: fun(
    (phase(), ast(), Extra) -> transformer_return(Extra)
).

-type analysis() :: #{
    attributes := #{
        spec => #{atom() => ast()},
        type => #{atom() => ast()},
        atom() => [ast()]
    },
    exports := [function_name()],
    file := string(),
    functions := [{atom(), pos_integer()}],
    imports := #{ module() => [function_name()]},
    module_imports := [module()],
    records := map(),
    errors | module | warnings => _
}.

-type function_name() :: atom() | {atom(), pos_integer()} | {module(), atom()}.

%%% @doc Transforms the given `Forms' using the given `Transformer' with the
%%% given `State'.
%%%
%%% This is done through three phases:
%%% 1, When you `enter' a subtree
%%% 2, When you encounter a leaf `node'
%%% 3, When you `exit' a subtree
%%%
%%% It's recommended to have a match-all clause to future proof your code.
% -spec transform(ast(), transformer(Extra), Extra) -> {Transformation, Extra}
% when
%     Transformation :: ast() | {warning, ast(), [term()]} | {error, [term()], [term()]}.
transform(Forms, Transformer, Extra) when is_function(Transformer, 3) ->
    InternalState = #state{
        file=merlin_lib:file(Forms),
        module=merlin_lib:module(Forms),
        transformer=Transformer,
        extra=Extra
    },
    logger:update_process_metadata(#{
        target => #{
            file => InternalState#state.file,
            line => none,
            module => InternalState#state.module,
            tranasformer => merlin_lib:fun_to_mfa(Transformer)
        }
    }),
    ?notice(
        "Transforming using ~s:~s/~p",
        tuple_to_list(merlin_lib:fun_to_mfa(Transformer))
    ),
    ?show(Forms),
    {TransformedTree, FinalState} = try
            transform_internal(Forms, InternalState)
        catch
            throw:Reason:Stacktrace ->
                %% compile:foldl_transform/3 uses a `catch F(...)` when calling parse
                %% transforms. Unfortuntely this means `throw`n errors turns into
                %% normal values.
                ?log_exception(throw, Reason, Stacktrace),
                erlang:raise(error, Reason, Stacktrace);
            Class:Reason:Stacktrace ->
                ?log_exception(Class, Reason, Stacktrace),
                erlang:raise(Class, Reason, Stacktrace)
        end,
    ?info("Final state ~tp", [FinalState#state.extra]),
    FinalTree = finalize(TransformedTree, FinalState),
    ?show(FinalTree),
    {FinalTree, FinalState#state.extra}.

%%% @private
-spec transform_internal(ast(), #state{}) -> {ast(), #state{}}.
transform_internal(Forms0, State0) when is_list(Forms0) ->
    {Forms1, State1} = lists:mapfoldl(fun transform_internal/2, State0, Forms0),
    {lists:flatten(Forms1), State1};
transform_internal(Form, State0) ->
    set_target_mfa(Form, State0),
    State1 = update_file(Form, State0),
    case erl_syntax:is_leaf(Form) of
        true ->
            {_Action, Node1, State2} = call_transformer(leaf, Form, State1),
            %% Here, at the leaf node, the action does not matter, as we're not
            %% recursing anymore.
            {Node1, State2};
        false ->
            {Action0, Tree1, State2} = call_transformer(enter, Form, State1),
            case Action0 of
                continue ->
                    State3 = increment_depth(State2),
                    {Tree2, State4} = mapfold_subtrees(
                        fun transform_internal/2, State3, Tree1
                    ),
                    State5 = decrement_depth(State4),
                    {_Action1, Tree3, State6} = call_transformer(
                        exit, Tree2, State5
                    ),
                    %% Like with the leaf node, we're not recursing here so
                    %% just return whatever result we've got.
                    {Tree3, State6};
                return ->
                    {Tree1, State2}
            end
    end.

update_file(Form, State) ->
    case get_file_attribute(Form) of
        false   -> State;
        NewFile ->
            ?info("Changing file ~s", [NewFile]),
            set_logger_target(file, NewFile),
            State#state{file = NewFile}
    end.

set_target_mfa(Node, #state{module=Module}) ->
    case erl_syntax:type(Node) of
        function ->
            Name = merlin_lib:value(erl_syntax:function_name(Node)),
            Arity = erl_syntax:function_arity(Node),
            set_logger_target(mfa, {Module, Name, Arity});
        _ -> ok
    end.

increment_depth(#state{depth=Depth} = State) ->
    set_logger_target(indent, lists:duplicate(Depth+1, "    ")),
    State#state{depth=Depth+1}.

decrement_depth(#state{depth=1} = State) ->
    unset_logger_target(indent),
    State#state{depth=0};
decrement_depth(#state{depth=Depth} = State) ->
    set_logger_target(indent, lists:duplicate(Depth-1, "    ")),
    State#state{depth=Depth-1}.

get_file_attribute(Form) ->
    case erl_syntax:type(Form) of
        file ->
            case erl_syntax:atom_value(erl_syntax:attribute_name(Form)) of
                file ->
                    [Filename, _Line] = erl_syntax:attribute_arguments(Form),
                    erl_syntax:string_value(Filename);
                _ ->
                    false
            end;
        _ -> false
    end.

-spec mapfold_subtrees(Fun, #state{}, ast() | [ast()]) -> {#state{}, [ast()]} when
    Fun :: fun((ast(), #state{}) -> {ast(), #state{}}).
mapfold_subtrees(Fun, State0, Tree0) ->
    case erl_syntax:subtrees(Tree0) of
        [] ->
            {Tree0, State0};
        Groups0 ->
            {Groups1, State1} = erl_syntax_lib:mapfoldl_listlist(
                Fun, State0, Groups0
            ),
            Groups2 = lists:map(fun lists:flatten/1, Groups1),
            Tree1 = erl_syntax:update_tree(Tree0, Groups2),
            {Tree1, State1}
    end.

%%% @private
%%% @doc Calls the user transformer and heavely normalizes its return value.
%%%
%%% The transformer may return many different tuples prefixed with 5
%%% different actions. This reduces that to just 2 actions and folds the
%%% returned updated nodes/errors/warnings into our internal state.
-spec call_transformer(phase(), ast(), #state{}) -> {Action, Tree, #state{}}
when
    Action :: continue | return,
    Tree :: ast(). %% erl_syntax:form_list
call_transformer(
    Phase,
    Node0,
    #state{
        transformer=Transformer,
        extra=Extra0,
        errors=ExistingErrors,
        warnings=ExistingWarnings
    } = State0)
->
    set_logger_target(line, erl_syntax:get_pos(Node0)),
    set_logger_target(state, Extra0),
    {Action, Node1, Extra1, Reasons} = expand_callback_return(
        Transformer(Phase, Node0, Extra0), Node0, Extra0
    ),
    First = case Node1 of
        [Head|_] -> Head;
        _ -> Node1
    end,
    set_logger_target(line, erl_syntax:get_pos(First)),
    set_logger_target(state, Extra1),
    ?info(
        "~s ~s -> ~s ~s",
        [Phase, erl_syntax:type(Node0), Action, erl_syntax:type(First)]
    ),
    % ?debug("Input ~tp", [Extra0]),
    % ?show("Input", Node0),
    % ?debug("Output ~tp", [Extra1]),
    % ?show("Output", Node1),
    State1 = State0#state{extra=Extra1},
    {Errors, Warnings} = format_markers(Reasons, First, State1),
    State2 = State1#state{
        errors=Errors ++ ExistingErrors,
        warnings=Warnings ++ ExistingWarnings
    },
    case Action of
        _ when length(Errors) > 0 ->
            {return, Node1, State2};
        exceptions ->
            {continue, Node1, State2};
        delete ->
            {return, [], State2};
        continue ->
            {continue, Node1, State2};
        return ->
            {return, Node1, State2}
    end.

%%% @private
%%% @doc Normalizes the return value from the user transformar into a
%%% consistent 4-tuple.
%%%
%%% This makes the {@link call_transformer/3} much simpler to write.
-spec expand_callback_return(Return, ast(), Extra)
    -> {action(), ast(), Extra, Reasons}
when
    Return ::
        Action |
        {continue | return, AST} |
        {continue | return, AST, Extra} |
        {error | warning, Reason} |
        {error, Reason, Extra} |
        {warning, Reason, AST} |
        {warning, Reason, AST, Extra} |
        {exceptions, Reasons, AST, Extra} |
        {action(), AST, Extra, Reasons} |
        {AST, Extra} |
        AST,
    Action :: continue | delete | return,
    AST :: ast() | [ast()],
    Extra :: term(),
    Reason :: term(),
    Reasons :: [{error | warning, Reason}].
expand_callback_return(Action, Node0, Extra0) when
    Action == continue orelse Action == delete orelse Action == return
->
    {Action, Node0, Extra0, []};
expand_callback_return({Action, Reason}, Node0, Extra0) when
    Action == error orelse Action == warning
->
    {exceptions, Node0, Extra0, [{Action, Reason}]};
expand_callback_return({error, Reason, Extra1}, Node0, _Extra0) ->
    {exceptions, Node0, Extra1, [{error, Reason}]};
expand_callback_return({warning, Reason, Node1}, _Node0, Extra0) ->
    {exceptions, Node1, Extra0, [{warning, Reason}]};
expand_callback_return({warning, Reason, Node1, Extra1}, _Node0, _Extra0) ->
    {exceptions, Node1, Extra1, [{warning, Reason}]};
expand_callback_return({exceptions, Exceptions, Node1, Extra1}, _Node0, _Extra0) ->
    {exceptions, Node1, Extra1, Exceptions};
expand_callback_return({delete, Extra1}, Node0, _Extra0) ->
    {delete, Node0, Extra1, []};
expand_callback_return({return, Node1}, _Node0, Extra0) ->
    {return, Node1, Extra0, []};
expand_callback_return({return, Node1, Extra1}, _Node0, _Extra0) ->
    {return, Node1, Extra1, []};
expand_callback_return({Action, Node1, Extra1, Reasons}, _Node0, _Extra0) when
    Action == continue orelse
    Action == delete orelse
    Action == return orelse
    Action == error orelse
    Action == warning
->
    %% Handle recursion, mostly useful for transform wrappers
    {Action, Node1, Extra1, Reasons};
expand_callback_return({continue, Node1, Extra1}, _Node0, _Extra0) ->
    {continue, Node1, Extra1, []};
expand_callback_return({Node1, Extra1}, _Node0, _Extra0) when
    is_tuple(Node1) % orelse is_tuple(hd(Node1))
->
    {continue, Node1, Extra1, []};
expand_callback_return(Nodes0, _Node0, Extra0) when is_list(Nodes0) ->
    Nodes1 = lists:flatten(Nodes0),
    lists:foreach(fun assert_valid_node/1, Nodes1),
    {continue, Nodes1, Extra0, []};
expand_callback_return(Node1, Node0, Extra0) ->
    case assert_valid_node(Node1) of
        form_list ->
            Nodes = erl_syntax:form_list_elements(Node1),
            expand_callback_return(Nodes, Node0, Extra0);
        _ ->
            {continue, Node1, Extra0, []}
    end.

assert_valid_node(Node) ->
    try
        erl_syntax:type(Node)
    catch error:{badarg, _} ->
        erlang:error({badsyntax, Node})
    end.

%%% @private
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
        ||
            {Type, Reason} <- Reasons
        ]
    ).

%%% @private
-spec format_marker(error,   term(), ast(), #state{}) -> error_marker();
                   (warning, term(), ast(), #state{}) -> warning_marker().
format_marker(Type, {File, {Position, FormattingModule, _Reason}} = Marker, _Node, #state{})
when
    (Type == error orelse Type == warning) andalso
    (File == [] orelse is_integer(hd(File))) andalso
    (is_integer(Position) orelse is_integer(element(1, Position))) andalso
    is_atom(FormattingModule)
->
    {Type, Marker};
format_marker(Type, Reason, Node, #state{
    file=File,
    module=Module
}) ->
    Position = erl_syntax:get_pos(Node),
    FormattingModule = case erlang:function_exported(Module, format_error, 1) of
        true ->
            Module;
         false ->
            merlin_lib
    end,
    {Type, {File, {Position, FormattingModule, Reason}}}.

-spec group_by_file(Exceptions) -> [{File :: string(), [marker()]}] when
    Exceptions :: [error_marker() | warning_marker() | marker()].
group_by_file(Exceptions) ->
    maps:to_list(lists:foldl(fun group_by_file/2, #{}, Exceptions)).

-spec group_by_file(Exception, Files) -> Files when
    Exception :: error_marker() | warning_marker() | marker(),
    Files :: #{ File => [marker()] },
    File :: string().
group_by_file({Type, {File, {Position, FormattingModule, _Reason}} = Marker}, Files)
when
    (Type == error orelse Type == warning) andalso
    (File == [] orelse is_integer(hd(File))) andalso
    (is_integer(Position) orelse is_integer(element(1, Position))) andalso
    is_atom(FormattingModule)
->
    group_by_file(Marker, Files);
group_by_file({File, Marker}, Files) ->
    Markers = maps:get(File, Files, []),
    Files#{
        File => [Marker|Markers]
    }.

%% @doc Like `erl_synatx_lib:analyze_forms' but returns maps.
%% Also all fields are present, except `module' so you can determine if it
%% exists or not. It also includes a `file' field and makes some fields
%% easier to use, like records being a map from name to definition.
-spec analyze([ast()]) -> analysis().
analyze(ModuleForms) ->
    Analysis = maps:from_list(erl_syntax_lib:analyze_forms(ModuleForms)),
    Analysis#{
        %% `module` is taken from Analysis if defined
        exports => maps:get(exports, Analysis, []),
        functions => maps:get(functions, Analysis, []),
        imports => get_as_map(Analysis, imports),
        attributes => attribute_map(Analysis),
        %% Seems unused, at least the docs does not mention carte blanc `-import`
        module_imports => maps:get(module_imports, Analysis, []),
        records => maps:map(
            fun record_fields_as_map/2, get_as_map(Analysis, records)
        ),

        %% Not part of the original, but so useful to have
        file => merlin_lib:file(ModuleForms)
    }.

%% @doc Same as `analyze/1`, but also extracts and appends any inline
%% `-compile` options to the given one.
analyze(ModuleForms, Options) ->
    Analysis = analyze(ModuleForms),
    CombinedOptions = case Analysis of
        #{ attributes := #{ compile := InlineOptions } } ->
            Options ++ lists:flatten(InlineOptions);
        _ ->
            Options
    end,
    {Analysis, CombinedOptions}.

%%% @private
get_as_map(Analysis, Key) ->
    maps:from_list(maps:get(Key, Analysis, [])).

%%% @private
record_fields_as_map(_Key, Fields) ->
    maps:from_list(Fields).

%%% @private
attribute_map(Analysis) when not is_map_key(attributes, Analysis) ->
    #{};
attribute_map(#{ attributes := [] }) ->
    #{};
attribute_map(#{ attributes := Attributes }) ->
    Groups = lists:foldl(fun pair_grouper/2, #{}, Attributes),
    Groups#{
        spec => group_by_name(maps:get(spec, Groups, [])),
        type => group_by_name(maps:get(type, Groups, []))
    }.

%% @private
%% @doc Groups the given list of two-tuples into a map.
group_pairs(Pairs) ->
    lists:foldl(fun pair_grouper/2, #{}, Pairs).

%% @private
pair_grouper({Type, Value}, Groups) ->
    Values = maps:get(Type, Groups, []),
    maps:put(Type, [Value|Values], Groups).

%% @private
%% @doc Groups the list of variable length tuples by their first element.
group_by_name(Tuples) ->
    group_pairs([ {element(1, Value), Value} || Value <- Tuples ]).


annotate(ModuleForms) ->
    annotate(ModuleForms, [bindings, resolve_calls, file]).

annotate(ModuleForms, Options) ->
    State = maps:merge(maps:from_list(proplists:unfold(Options)), #{
        analysis => analyze(ModuleForms)
    }),
    {Forms, _} = transform(ModuleForms, fun annotate_internal/3, State),
    Forms.

annotate_internal(enter, Form0, #{ analysis := Analysis0 } = State0) ->
    Analysis1 = case get_file_attribute(Form0) of
        false   -> Analysis0;
        NewFile -> Analysis0#{file => NewFile}
    end,
    State1 = State0#{ analysis => Analysis1 },
    Form1 = case State1 of
        #{ file := true, analysis := #{ file := File } } ->
            merlin_lib:set_annotation(Form0, file, File);
        _ ->
            Form0
    end,
    case annotate_form(erl_syntax:type(Form1), Form1, State1) of
        {error, _}   = Form2 -> Form2;
        {warning, _} = Form2 -> Form2;
        Form2                -> {continue, Form2, State1}
    end;
annotate_internal(_, _, _) -> continue.

annotate_form(application, Form, #{
    analysis := Analysis ,
    resolve_calls := true
}) ->
    case resolve_call(Form, Analysis) of
        {module, _} = Result ->
            erl_syntax:add_ann(Result, Form);
        dynamic ->
            %% Dynamic value, can't resolve
            Form;
        ErrorOrWarning ->
            ErrorOrWarning
    end;
annotate_form(function, Form, #{
    bindings := Bindings,
    analysis := #{
        attributes := Attributes,
        exports := Exports
    }
}) ->
    Specs = maps:get(spec, Attributes, #{}),
    Name = erl_syntax:atom_value(erl_syntax:function_name(Form)),
    Arity = erl_syntax:function_arity(Form),
    FunctionArity = {Name, Arity},
    IsExported = lists:member({Name, Arity}, Exports),
    Form1 = merlin_lib:set_annotation(Form, is_exported, IsExported),
    Form2 = case Specs of
        #{ FunctionArity := Spec } ->
            merlin_lib:set_annotation(Form, spec, Spec);
        _ ->
            Form1
    end,
    if Bindings ->
        Env = merlin_lib:get_annotation(Form2, env, ordsets:new()),
        erl_syntax_lib:annotate_bindings(Form2, Env);
    ?else ->
        Form2
    end;
annotate_form(module, Form, #{ analysis := Analysis }) ->
    merlin_lib:set_annotation(Form, analysis, Analysis);
annotate_form(_, Form, _) -> Form.

resolve_call(Node, #{
    functions := Functions,
    imports := Imports
} = Analysis) ->
    Operator = erl_syntax:application_operator(Node),
    case erl_syntax:type(Operator) of
        module_qualifier ->
            %% Remote call
            CallModule = erl_syntax:atom_value(
                erl_syntax:module_qualifier_argument(Operator)
            ),
            {module, CallModule};
        atom ->
            %% Local call
            Name = erl_syntax:atom_value(Operator),
            Arity = length(erl_syntax:application_arguments(Node)),
            Function = {Name, Arity},
            case lists:member(Function, Functions) of
                true ->
                    %% Function defined in this module
                    case Analysis of
                        #{ module := CallModule } ->
                            {module, CallModule};
                        _ ->
                            {warning, "Missing -module, can't resolve local function calls"}
                    end;
                false ->
                    case [
                            CallModule
                        ||
                            {CallModule, ImportedFunctions} <- maps:to_list(Imports),
                            lists:member(Function, ImportedFunctions)
                    ] of
                        [CallModule] ->
                            {module, CallModule};
                        [] ->
                            %% Assume all other calls refer to builtin functions
                            %% Maybe add a sanity check for compile no_auto_import?
                            {module, erlang};
                        CallModules ->
                            ListPhrase = list_phrase(CallModules),
                            Message = lists:flatten(io_lib:format(
                                "Overlapping -import for ~tp/~tp from ~s",
                                [Name, Arity, ListPhrase]
                            )),
                            {error, Message}
                    end
            end;
        _ ->
            %% Dynamic value, can't resolve
            dynamic
    end.

list_phrase(List) ->
    CommaSeperatedList = lists:join(", ", List),
    LastCommaReplacedWithAnd = string:replace(
        CommaSeperatedList, ", ", " and ", trailing
    ),
    lists:concat(LastCommaReplacedWithAnd).

%%% @doc
return({Result, _State}) ->
    merlin_internal:write_log_file(),
    return(Result);
return({warning, Tree, Warnings}) ->
    merlin_internal:write_log_file(),
    {warning, revert(Tree), Warnings};
return({error, _Error, _Warnings} = Result) ->
    merlin_internal:write_log_file(),
    Result;
return(Tree) ->
    merlin_internal:write_log_file(),
    revert(Tree).

%%% @private
%%% @doc Returns an {@link er_lint} compatible forms, with errors and
%%% warnings as appropriate.
%%%
%%% This matches the `case' in {@link compile:foldl_transform/3}.
finalize(Tree, #state{errors=[], warnings=[]}) ->
    Tree;
finalize(Tree, #state{errors=[], warnings=Warnings}) ->
    {warning, Tree, group_by_file(Warnings)};
finalize(_Tree, #state{errors=Errors, warnings=Warnings}) ->
    {error, group_by_file(Errors), group_by_file(Warnings)}.

%%% @doc Reverts back from Syntax Tools format to Erlang forms.
%%%
%%% Accepts a list of forms, or a single form.
%%%
%%% Copied from `parse_trans:revert_form/1' and slighly modifed. The original
%%% also handles a bug in R16B03, but that is ancient history now.
revert(Forms) when is_list(Forms) ->
    lists:map(fun revert/1, Forms);
revert(Form) ->
    case erl_syntax:revert(Form) of
        {attribute, Line, Arguments, Tree} when element(1, Tree) == tree ->
            {attribute, Line, Arguments, erl_syntax:revert(Tree)};
        Result -> Result
    end.

get_logger_target() ->
    case logger:get_process_metadata() of
        undefined -> #{};
        Metadata -> maps:get(target, Metadata, #{})
    end.

% get_logger_target(Key, Default) ->
%     maps:get(Key, get_logger_target(), Default).

set_logger_target(Key, Value) ->
    logger:update_process_metadata(#{
        target => maps:put(Key, Value, get_logger_target())
    }).

unset_logger_target(Key) ->
    logger:update_process_metadata(#{
        target => maps:remove(Key, get_logger_target())
    }).