-module(merlin_lib).

-include("log.hrl").

-export([
    file/1,
    module/1,
    quote/3,
    value/1
]).

-export([
    format_error/1
]).

-export([
    erl_error_format/2,
    format_error_marker/2,
    fun_to_mfa/1,
    split_by/2
]).

-export([
    get_annotation/2,
    get_annotation/3,
    set_annotation/3,
    update_annotation/2
]).

-export([
    get_attribute/3,
    get_attribute_forms/2,
    get_attributes/2
]).

-export([
    add_binding/2,
    add_bindings/2,
    bindings_with_type/1,
    get_bindings/1
]).

-export([
    add_new_variable/1,
    add_new_variable/2,
    add_new_variable/3,
    add_new_variables/2,
    add_new_variables/3,
    add_new_variables/4,
    new_variable/1,
    new_variable/2,
    new_variable/3,
    new_variables/1,
    new_variables/2,
    new_variables/3,
    new_variables/4
]).

-define(else, true).

-define(variable_formatter,
    fun(N) ->
        binary_to_atom(iolist_to_binary(io_lib:format("~s~p~s", [Prefix, N, Suffix])))
    end
).

%%% @doc Returns the filename for the first `-file' attribute in `Forms', or
%%% `""' if not found.
-spec file([merlin:ast()]) -> string().
file(Forms) ->
    case get_attribute(Forms, file, undefined) of
        undefined -> "";
        [FileAttribute, _Line] -> erl_syntax:string_value(FileAttribute)
    end.

%%% @doc Returns the module name for the first `-module' attribute in
%%% `Forms', or <code>''</code> if not found.
-spec module([merlin:ast()]) -> module() | ''.
module(Forms) ->
    case get_attributes(Forms, module) of
        [[ModuleAttribute|_MaybeParameterizedModuleArgument]|_] ->
            erl_syntax:atom_value(ModuleAttribute);
        _ -> ''
    end.

quote(File0, Line0, Source0) ->
    File1 = safe_value(File0),
    Line1 = safe_value(Line0),
    Source1 = safe_value(Source0),
    try
        merl:quote(Line1, Source1)
    of AST ->
        {ok, AST}
    catch throw:{error, SyntaxError} ->
        {error, {File1, {Line1, ?MODULE, SyntaxError}}}
    end.

safe_value(Node) when is_tuple(Node) ->
    value(Node);
safe_value(Value) ->
    Value.

%%% @doc Callback for formatting error messages from this module
%%%
%%% @see erl_parse:format_error/1
format_error(Message0) ->
    Message1 = case io_lib:deep_char_list(Message0) of
        true ->
            Message0;
        _ ->
            io_lib:format("~tp", [Message0])
    end,
    case re:run(Message1, "^\\d+: (.+)$", [{capture, all_but_first, list}]) of
        {match, [Message2]} -> Message2;
        nomatch -> Message1
    end.

-spec format_error_marker(Reason, Stacktrace | Node) -> merlin:error_marker() when
    Reason :: term(),
    Stacktrace :: list({module(), atom(), arity(), [{atom(), term()}]}),
    Node :: merlin:ast().
format_error_marker(Reason, [{_Module, _Function, _Arity, Location}|_]) ->
    File = keyfind(Location, file, none),
    Line = keyfind(Location, line, 0),
    {error, {File, {Line, ?MODULE, Reason}}};
format_error_marker(Reason, Node) when is_tuple(Node) ->
    File = get_annotation(Node, file),
    Position = erl_syntax:get_pos(Node),
    {error, {File, {Position, ?MODULE, Reason}}}.

keyfind(List, Key, Default) ->
    case lists:keyfind(Key, 1, List) of
        {Key, Value} -> Value;
        false ->
            case get(Key) of
                undefined -> Default;
                Value -> Value
            end
    end.

erl_error_format(Reason, StackTrace) ->
    Indent = 1,
    Class = error,
    %% Ignore all frames to keep the message on one line
    StackFilter = fun(_M, _F, _A) -> true end,
    Formatter = fun(Term, _Indent) -> io_lib:format("~tp", [Term]) end,
    Encoding = utf8,
    erl_error:format_exception(
        Indent, Class, Reason, StackTrace, StackFilter, Formatter, Encoding
    ).

fun_to_mfa(Fun) when is_function(Fun) ->
    #{
        module := Module,
        name := Name,
        arity := Arity
    } = maps:from_list(erlang:fun_info(Fun)),
    {Module, Name, Arity}.

%%% @doc Get all bindings associated with the given `Form'.
%%%
%%% Returns a map from binding name to kind, prefering bound over env over
%%% free.
%%%
%%% @see with_bindings/2
%%% @see erl_syntax_lib:annotate_bindings/2
bindings_with_type(Form) ->
    #{
        env := Env,
        bound := Bound,
        free := Free
    } = get_annotations(Form),
    Bindings = ordsets:union([
        Env, Bound, Free
    ]),
    maps:from_list([
        if
            is_map_key(bound, Bound) -> {Binding, bound};
            is_map_key(env, Env)     -> {Binding, env};
            is_map_key(free, Free)   -> {Binding, free}
        end
    ||
        Binding <- Bindings
    ]).

%%% @doc Returns the annotation for the given form,
%%% or raises `{badkey, Annotation}' if not found.
get_annotation(Form, Annotation) ->
    Annotations = get_annotations(Form),
    maps:get(Annotation, Annotations).

%%% @doc Returns the annotation for the given form,
%%% or Default if not found.
get_annotation(Form, Annotation, Default) ->
    Annotations = get_annotations(Form),
    maps:get(Annotation, Annotations, Default).

%%% @doc Returns all annotations associated with the given `Form' as a map.
get_annotations(Form) ->
    maps:from_list(erl_syntax:get_ann(Form)).

set_annotation(Form, Annotation, Value) ->
    update_annotation(Form, #{ Annotation => Value }).

update_annotation(Form, NewAnnotations) ->
    Annotations = get_annotations(Form),
    UpdatedAnnotations = maps:merge(Annotations, NewAnnotations),
    erl_syntax:set_ann(Form, maps:to_list(UpdatedAnnotations)).

%%% @doc Returns the argument to the first module attribute with the given
%%% name, or Default if not found.
-spec get_attribute(merlin:ast(), atom(), term()) -> term().
get_attribute(Tree, Name, Default) ->
    case lists:search(attribute_filter(Name), Tree) of
        {value, Node} -> erl_syntax:attribute_arguments(Node);
        false -> Default
    end.

%%% @doc Returns the arguments to all attributes with the given name in the
%%% given list of forms.
%%%
%%% Returns the empty list if no such attributes are found.
get_attributes(Tree, Name) ->
    lists:map(fun erl_syntax:attribute_arguments/1,
        get_attribute_forms(Tree, Name)
    ).

%%% @doc Returns all attributes with the given name in the given list of forms.
get_attribute_forms(Tree, Name) ->
    lists:filter(attribute_filter(Name), Tree).

%%% @private
attribute_filter(Name) ->
    fun(Node) ->
        erl_syntax:type(Node) == attribute andalso
        value(erl_syntax:attribute_name(Node)) == Name
    end.

%%% @doc Returns the value of the given literal node as an Erlang term.
%%%
%%% Raises `{badvalue, Node}' if the given `Node' is not an literal node.
value(Node) ->
    case erl_syntax:is_literal(Node) of
        true ->
            ValueFunction = binary_to_atom(iolist_to_binary(io_lib:format(
                "~s_value", [erl_syntax:type(Node)]
            )), utf8),
            case erlang:function_exported(erl_syntax, ValueFunction, 1) of
                true -> erl_syntax:ValueFunction(Node);
                false -> error({badvalue, Node})
            end;
        false -> error({badvalue, Node})
    end.

split_by(List, Fun) when is_list(List) andalso is_function(Fun, 1) ->
    split_by(List, Fun, []).

split_by([], _Fun, Acc) ->
    {lists:reverse(Acc), undefined, []};
split_by([Head|Tail], Fun, Acc) ->
    case Fun(Head) of
        true  -> {lists:reverse(Acc), Head, Tail};
        false -> split_by(Tail, Fun, [Head|Acc])
    end.

add_new_variable(Bindings) ->
    Var = new_variable(Bindings),
    {Var, add_binding(Bindings, Var)}.

add_new_variable(Bindings, Prefix) ->
    Var = new_variable(Bindings, Prefix),
    {Var, add_binding(Bindings, Var)}.

add_new_variable(Bindings, Prefix, Suffix) ->
    Var = new_variable(Bindings, Prefix, Suffix),
    {Var, add_binding(Bindings, Var)}.

add_new_variables(Bindings, Total) ->
    Vars = new_variables(Bindings, Total),
    {Vars, add_bindings(Bindings, Vars)}.

add_new_variables(Bindings, Total, Prefix) ->
    Vars = new_variables(Bindings, Total, Prefix),
    {Vars, add_bindings(Bindings, Vars)}.

add_new_variables(Bindings, Total, Prefix, Suffix) ->
    Vars = new_variables(Bindings, Total, Prefix, Suffix),
    {Vars, add_bindings(Bindings, Vars)}.

new_variable(Bindings) ->
    new_variable(get_bindings(Bindings), "__Var", "__").

new_variable(Bindings, Prefix) ->
    new_variable(Bindings, Prefix, "").

new_variable(Bindings, Prefix, Suffix) ->
    Set = get_bindings(Bindings),
    erl_syntax_lib:new_variable_name(?variable_formatter, Set).

new_variables(Total) when is_integer(Total) ->
    new_variables(sets:new(), Total).

new_variables(Bindings, Total) ->
    new_variables(get_bindings(Bindings), Total, "__Var", "__").

new_variables(Bindings, Total, Prefix) ->
    new_variables(Bindings, Total, Prefix, "").

new_variables(Bindings, Total, Prefix, Suffix) ->
    Set = get_bindings(Bindings),
    erl_syntax_lib:new_variable_names(Total, ?variable_formatter, Set).

%%% @doc Get all bindings associated with the given `Value'.
get_bindings(#{ bindings := Bindings }) ->
    Bindings;
get_bindings(#{ env := Env, bound := Bound, free := Free }) ->
    sets:from_list(lists:flatten([Env, Bound, Free]));
get_bindings(BindingsOrForm) ->
    case sets:is_set(BindingsOrForm) of
        true ->
            BindingsOrForm;
        false ->
            get_bindings(get_annotations(BindingsOrForm))
    end.

add_binding(Bindings, NewBinding) ->
    add_bindings(Bindings, [NewBinding]).

add_bindings(#{ bindings := Bindings } = Input, NewBindings) ->
    Input#{ bindings => add_bindings(Bindings, NewBindings) };
add_bindings(#{ env := Env, bound := Bound, free := Free } = Input, NewBindings) ->
    AllBindings = ordsets:union([Env, Bound, Free]),
    case ordsets:is_subset(NewBindings, AllBindings) of
        true -> Input;
        false ->
            New = ordsets:subtract(NewBindings, AllBindings),
            Input#{ bound => ordsets:union(Bound, New) }
    end;
add_bindings(BindingsOrForm, NewBindings) ->
    case sets:is_set(BindingsOrForm) of
        true ->
            Set = if is_list(NewBindings) ->
                sets:from_list(NewBindings);
            ?else ->
                NewBindings
            end,
            sets:union(BindingsOrForm, Set);
        false ->
            update_annotation(
                BindingsOrForm,
                add_binding(get_annotations(BindingsOrForm), NewBindings)
            )
    end.