-module(merlin).

-type ast() :: erl_syntax:syntaxTree().

-type phase() :: enter | node | exit.

-type transformer(Extra) :: fun(
    (phase(), ast(), Extra) ->
        ast() | {ast(), Extra} |
        continue | {continue, ast()} | {continue, ast(), Extra} |
        return   | {return,   ast()} | {return,   ast(), Extra} |
        delete   | {delete,   Extra} |
        {error,   term()} | {error,   term(), Extra} |
        {warning, term()} | {warning, term(), Extra}
).

-record(state, {
    file :: string(),
    module :: module(),
    transformer :: transformer(Extra),
    extra :: Extra
}).

-export([
    with_binding/3,
    get_attribute/3,
    get_bindings/1,
    get_bindings/2,
    transform/3
]).

%%% @doc Transforms the given `Forms' using the given `Transformer' with the
%%%      given `State'.
%%%
%%%      This is done through three phases:
%%%      1, When you `enter' a subtree
%%%      2, When you encounter a leaf `node'
%%%      3, When you `exit' a subtree
%%%
%%%      It's recommended to have a match-all clause to future proof your code.
-spec transform(ast(), transformer(Extra), Extra) -> {ast(), Extra}.
transform(Forms, Transformer, Extra) when is_function(Transformer, 3) ->
    File = case get_attribute(Forms, file, undefined) of
        undefined -> "undefined";
        [FileAttribute|_] -> erl_syntax:string_value(FileAttribute)
    end,
    Module = case get_attribute(Forms, module, undefined) of
        undefined -> undefined;
        [ModuleAttribute|_] -> erl_syntax:atom_value(ModuleAttribute)
    end,
    InternalState = #state{
        file=File,
        module=Module,
        transformer=Transformer,
        extra=Extra
    },
    {TransformedTree, FinalState} = transform_internal(Forms, InternalState),
    ErrorsAndWarnings = extract_errors_and_warnings(TransformedTree, {[], []}),
    JustForms = filter(TransformedTree, fun not_errors_or_warnings/1),
    FinalTree = case ErrorsAndWarnings of
        {[], []} -> JustForms;
        {[], Warnings} -> {warnings, JustForms, Warnings};
        {Errors, Warnings} -> {error, Errors, Warnings}
    end,
    {FinalTree, FinalState#state.extra}.

%%% @private
-spec transform_internal(ast(), #state{}) -> {ast(), #state{}}.
transform_internal(Forms, State) when is_list(Forms) ->
    lists:mapfoldl(fun transform_internal/2, State, Forms);
transform_internal(delete, State) ->
    {delete, State};
transform_internal(Form, #state{} = State0) ->
    case erl_syntax:is_leaf(Form) of
        true ->
            {_Action, Node1, State1} = call_transformer(node, Form, State0),
            %% Here, at the leaf node, the action does not matter, as we're not
            %% recursing anymore.
            {Node1, State1};
        false ->
            {Action0, Tree1, State1} = call_transformer(enter, Form, State0),
            case Action0 of
                continue ->
                    {Tree2, State2} = erl_syntax_lib:mapfold_subtrees(
                        fun transform_internal/2, State1, Tree1
                    ),
                    Tree3 = filter_subtree(Tree2, fun not_deleted/1),
                    {_Action1, Tree4, State3} = call_transformer(
                        exit, Tree3, State2
                    ),
                    %% Like with the lef node, we're not recursing here so
                    %% just return whatever result we've got.
                    {Tree4, State3};
                _ -> {Tree1, State1}
            end
    end.

call_transformer(
    Phase,
    Node0,
    #state{
        transformer=Transformer,
        extra=Extra0
    } = State0)
->
    {Action, NewNode, NewExtra} = case Transformer(Phase, Node0, Extra0) of
        {error, Reason} ->
            ErrorMarker = format_marker(error, Reason, Node0, State0),
            {return, ErrorMarker, Extra0};
        {error, Reason, Extra1} ->
            ErrorMarker = format_marker(error, Reason, Node0, State0),
            {return, ErrorMarker, Extra1};
        {warning, Reason} ->
            WarningMarker = format_marker(warning, Reason, Node0, State0),
            {return, WarningMarker, Extra0};
        {warning, Reason, Extra1} ->
            WarningMarker = format_marker(warning, Reason, Node0, State0),
            {return, WarningMarker, Extra1};
        delete ->
            {delete, delete, Extra0};
        {delete, Extra1} ->
            {delete, delete, Extra1};
        return ->
            {return, Node0, Extra0};
        {return, Node1} ->
            {return, Node1, Extra0};
        {return, Node1, Extra1} ->
            {return, Node1, Extra1};
        continue ->
            {continue, Node0, Extra0};
        {Node1, Extra1} when is_tuple(Node1) ->
            {continue, Node1, Extra1};
        Node1 ->
            try
                erl_syntax:type(Node1)
            of _ ->
                {continue, Node1, Extra0}
            catch error:{badarg, _} ->
                erlang:error({badsyntax, Node1})
            end
    end,
    {Action, NewNode, State0#state{extra=NewExtra}}.

%%% @private
format_marker(Type, Reason, Node, #state{
    file=File,
    module=Module
}) ->
    Position = erl_syntax:get_pos(Node),
    {Type, {File, {Position, Module, Reason}}}.

%%% @private
not_deleted(delete) -> false;
not_deleted(_) -> true.

%%% @private
not_errors_or_warnings({error, _}) -> false;
not_errors_or_warnings({warning, _}) -> false;
not_errors_or_warnings(_) -> true.

%%% @private
extract_errors_and_warnings(Trees, ErrorsAndWarnings) when is_list(Trees) ->
    lists:foldl(fun extract_errors_and_warnings/2, ErrorsAndWarnings, Trees);
extract_errors_and_warnings(Tree, ErrorsAndWarnings) ->
    erl_syntax_lib:fold(fun extractor/2, ErrorsAndWarnings, Tree).

extractor({warning, Warning}, {Errors, Warnings}) ->
    {Errors, [Warning|Warnings]};
extractor({error, Error}, {Errors, Warnings}) ->
    {[Error|Errors], Warnings};
extractor(_Tree, {Errors, Warnings}) -> {Errors, Warnings}.

filter_subtree(Tree, Filter) when is_function(Filter, 1) ->
    case erl_syntax:subtrees(Tree) of
        [] ->
            Tree;
        Groups ->
            erl_syntax:update_tree(Tree, [
                [
                    Subtree
                ||
                    Subtree <- Group,
                    Filter(Subtree)
                ]
            ||
                Group <- Groups
            ])
    end.

filter(Tree, Filter) when is_function(Filter, 1) ->
    State = #state{transformer=fun filter_internal/3, extra=Filter},
    transform_internal(Tree, State).

%%% @private
filter_internal(node, Node, Filter) ->
    case Filter(Node) of
        true  -> {Node, Filter};
        false -> delete
    end;
filter_internal(_, Forms, Filter) -> {Forms, Filter}.

%%% @doc Annotates function definitions with the bindings using
%%%      `erl_syntax_lib:with_bindings/2' before calling the inner
%%%      transformer.
%%%
%%%      This allows the inner transformer to safely generate new
%%%      bindings, or otherwise act on the current set of env, free and bound
%%%      bindings.
%%%
%%%      @see erl_syntax_lib:annotate_bindings/2
-spec with_binding(ast(), transformer(Extra), Extra) -> transformer(Extra).
with_binding(Forms, Transformer, Extra) ->
    InternalState = #state{transformer=Transformer, extra=Extra},
    transform(Forms, fun with_binding_internal/3, InternalState).

%%% @private
with_binding_internal(
    enter,
    {function, _Line, _Name, _Arity, _Clauses} = Function0,
    #state{transformer=Transformer, extra=Extra0} = State)
->
    Function1 = erl_syntax_lib:with_binding(Function0, ordsets:new()),
    {Function2, Extra1} = Transformer(enter, Function1, Extra0),
    {Function2, State#state{extra=Extra1}};
with_binding_internal(
    Phase,
    Form0,
    #state{transformer=Transformer, extra=Extra0} = State)
->
    {Form1, Extra1} = Transformer(Phase, Form0, Extra0),
    {Form1, State#state{extra=Extra1}}.

%%% @doc Get all bindings associated with the given `Form'.
%%%
%%%      Returns a sorted proplist from binding to kind, prefering bound over
%%%      env over free.
%%%
%%%      @see get_bindings/2
%%%      @see with_binding/2
%%%      @see erl_syntax_lib:annotate_bindings/2
get_bindings(Form) ->
    Env = bindings_with_kind(Form, env),
    Bound = bindings_with_kind(Form, bound),
    Free = bindings_with_kind(Form, free),
    %% Prefer Bound over Env over Free
    lists:ukeymerge(1, Bound, lists:ukeymerge(1, Env, Free)).

%%% @private
bindings_with_kind(Form, Kind) ->
    lists:keysort(1, [{Binding, Kind} || Binding <- get_bindings(Form, Kind)]).

%%% @doc Get all bindings of the given `Kind' associated with the given `Form'.
%%%
%%%      @see with_binding/2
%%%      @see erl_syntax_lib:annotate_bindings/2
-spec get_bindings(ast(), env | bound | free) -> ordsets:ordset(atom()).
get_bindings(Form, Kind) ->
    Annotations = erl_syntax:get_ann(Form),
    case lists:keyfind(Kind, 1, Annotations) of
        false -> throw({badkey, Kind});
        Value -> Value
    end.

get_attribute(Tree, Name, Default) ->
    case lists:search(fun(Node) ->
        erl_syntax:type(Node) == attribute andalso
        erl_syntax:atom_value(erl_syntax:attribute_name(Node)) == Name
    end, Tree) of
        {value, Node} -> erl_syntax:attribute_arguments(Node);
        false -> Default
    end.

%% Example
printer(enter, Tree, Indentation) ->
    Type = erl_syntax:type(Tree),
    io:format("~s~p~n", [lists:duplicate(Indentation, "  "), Type]),
    {Tree, Indentation+1};
printer(node, Node, Indentation) ->
    Type = erl_syntax:type(Node),
    {_, _, Value} = erl_syntax:revert(Node),
    io:format("~s~p ~p~n", [lists:duplicate(Indentation, "  "), Type, Value]),
    {Node, Indentation};
printer(exit, Tree, Indentation) ->
    Type = erl_syntax:type(Tree),
    io:format("~send ~p~n", [lists:duplicate(Indentation-1, "  "), Type]),
    {Tree, Indentation-1}.