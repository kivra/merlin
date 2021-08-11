-module(merlin_lib).

-include("internal.hrl").

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
    into_error_marker/2
]).

-export([
    get_annotation/2,
    get_annotation/3,
    get_annotations/1,
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
    get_bindings/1,
    get_bindings_with_type/1
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

-export_type([
    bindings/0,
    bindings_by_type/0,
    bindings_or_form/0
]).

-define(else, true).

-ifndef(TEST).
-define(variable_formatter,
    fun(N) ->
        binary_to_atom(iolist_to_binary(io_lib:format("~s~p~s", [Prefix, N, Suffix])))
    end
).
-else.
%% During testing we ignore the randomly generated N, and use the process
%% dictionary to keep track of the next number. This is to allow writing
%% deterministic tests.
%%
%% It use multiple counters, one per prefix/suffix combination. This makes it
%% much easier to guess what the automatic variable will be.
-define(variable_formatter,
    fun(_N) ->
        test_variable_formatter(Prefix, Suffix)
    end
).

test_variable_formatter(Prefix0, Suffix0) ->
    Prefix1 = iolist_to_binary(io_lib:format("~s", [Prefix0])),
    Suffix1 = iolist_to_binary(io_lib:format("~s", [Suffix0])),
    Key = {'merlin_lib:variable_counter', Prefix1, Suffix1},
    N = case erlang:get(Key) of
        undefined -> 1;
        Number -> Number
    end,
    put(Key, N + 1),
    binary_to_atom(iolist_to_binary(io_lib:format("~s~p~s", [Prefix1, N, Suffix1]))).
-endif.

-define(is_binding_type(Type),
    (Type =:= bound orelse Type =:= env orelse Type =:= free)
).

-define(ERL_ANNO_KEYS, [file, generated, location, record, text]).

-type variable() :: atom() | merlin:ast().

-type set() :: set(variable()).
-type set(T) :: sets:set(T) | ordsets:ordset(T).

-type bindings() ::
    bindings_by_type()
    | #{bindings := bindings_by_type()}
    | set(variable()).

-type bindings_by_type() :: #{
    env := ordsets:set(variable()),
    bound := ordsets:set(variable()),
    free :=  ordsets:set(variable())
}.

-type bindings_or_form() :: bindings() | merlin:ast().

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

-spec into_error_marker(Reason, Stacktrace | Node) -> merlin:error_marker() when
    Reason :: term(),
    Stacktrace :: list({module(), atom(), arity(), [{atom(), term()}]}),
    Node :: merlin:ast().
into_error_marker(Reason, [{_Module, _Function, _Arity, Location}|_]) ->
    File = keyfind(Location, file, none),
    Line = keyfind(Location, line, 0),
    {error, {File, {Line, ?MODULE, Reason}}};
into_error_marker(Reason, Node) when is_tuple(Node) ->
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

%%% @doc Get all bindings associated with the given `Form'.
%%%
%%% Returns a map from binding name to kind, prefering bound over env over
%%% free.
%%%
%%% @see with_bindings/2
%%% @see erl_syntax_lib:annotate_bindings/2
get_bindings_with_type(Form) ->
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
    {ErlAnno, ErlSyntax} = get_annotations_internal(Form),
    maps:merge(maps:from_list(ErlAnno), ErlSyntax).

set_annotation(Form, Annotation, Value) ->
    update_annotation(Form, #{ Annotation => Value }).

update_annotation(Form, NewAnnotations) ->
    {ErlAnno, ErlSyntax} = get_annotations_internal(Form),
    {NewErlAnno, NewErlSyntax} = lists:partition(
        fun is_erl_anno/1, maps:to_list(NewAnnotations)
    ),
    UpdatedErlAnno = lists:foldl(fun set_erl_anno/2, ErlAnno, NewErlAnno),
    UpdatedErlSyntax = maps:merge(ErlSyntax, maps:from_list(NewErlSyntax)),
    Form1 = erl_syntax:set_pos(Form, UpdatedErlAnno),
    erl_syntax:set_ann(Form1, maps:to_list(UpdatedErlSyntax)).

%% @private
%% @doc Returns all annotations from {@link erl_anno} and {@link erl_syntax}.
get_annotations_internal(Form) ->
    Anno = erl_syntax:get_pos(Form),
    ErlAnno = [
        {Name, get_erl_anno(Name, Anno)}
    ||
        Name <- ?ERL_ANNO_KEYS,
        get_erl_anno(Name, Anno) =/= undefined
    ],
    ErlSyntax = maps:from_list(erl_syntax:get_ann(Form)),
    ?assertEqual(
        [],
        ordsets:intersection(
            ?ERL_ANNO_KEYS, ordsets:from_list(maps:keys(ErlSyntax))
        ),
        "erl_anno keys must not be saved as erl_syntax annotations"
    ),
    {ErlAnno, ErlSyntax}.

%% @private
is_erl_anno({file, _Value}) -> true;
is_erl_anno({generated, _Value}) -> true;
is_erl_anno({location, _Value}) -> true;
is_erl_anno({record, _Value}) -> true;
is_erl_anno({text, _Value}) -> true;
is_erl_anno({_Key, _Value}) -> false.

%% @private
get_erl_anno(file, Anno) ->
    erl_anno:file(Anno);
get_erl_anno(generated, Anno) ->
    erl_anno:generated(Anno) orelse undefined;
get_erl_anno(location, Anno) ->
    erl_anno:location(Anno);
get_erl_anno(record, Anno) ->
    erl_anno:record(Anno) orelse undefined;
get_erl_anno(text, Anno) ->
    erl_anno:text(Anno);
get_erl_anno(_, _) ->
    undefined.

%% @private
set_erl_anno({file, File}, Anno) ->
    erl_anno:set_file(File, Anno);
set_erl_anno({generated, Generated}, Anno) ->
    erl_anno:set_generated(Generated, Anno);
set_erl_anno({location, Location}, Anno) ->
    erl_anno:set_location(Location, Anno);
set_erl_anno({record, Record}, Anno) ->
    erl_anno:set_record(Record, Anno);
set_erl_anno({text, Text}, Anno) ->
    erl_anno:set_text(Text, Anno).

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

%% @doc Same as {@link add_new_variable/3} with default prefix and suffix.
%%
%% @see new_variable/3
add_new_variable(BindingsOrForm) ->
    Var = new_variable(BindingsOrForm),
    {Var, add_binding(BindingsOrForm, Var)}.

%% @doc Same as {@link add_new_variable/3} with the given prefix and default
%% suffix.
%%
%% @see new_variable/3
add_new_variable(BindingsOrForm, Prefix) ->
    Var = new_variable(BindingsOrForm, Prefix),
    {Var, add_binding(BindingsOrForm, Var)}.

%% @doc Creates a new variable using {@link new_variable/3} and adds it to the
%% given form or bindings.
%%
%% @see new_variable/3
add_new_variable(BindingsOrForm, Prefix, Suffix) ->
    Var = new_variable(BindingsOrForm, Prefix, Suffix),
    {Var, add_binding(BindingsOrForm, Var)}.

%% @doc Same as {@link new_variables/3} with default prefix and suffix.
%%
%% @see new_variable/3
add_new_variables(BindingsOrForm, Total) ->
    Vars0 = new_variables(BindingsOrForm, Total),
    Vars1 = maybe_form(BindingsOrForm, Vars0),
    {Vars1, add_bindings(BindingsOrForm, Vars0)}.

%% @doc Same as {@link new_variable/3} with the given prefix and default
%% suffix.
%%
%% @see new_variable/3
add_new_variables(BindingsOrForm, Total, Prefix) ->
    Vars0 = new_variables(BindingsOrForm, Total, Prefix),
    Vars1 = maybe_form(BindingsOrForm, Vars0),
    {Vars1, add_bindings(BindingsOrForm, Vars0)}.

%% @doc Creates `Total' number of new variables using {@link new_variables/4}
%% and adds it to the given form or bindings.
%%
%% @see new_variable/3
add_new_variables(BindingsOrForm, Total, Prefix, Suffix) ->
    Vars0 = new_variables(BindingsOrForm, Total, Prefix, Suffix),
    Vars1 = maybe_form(BindingsOrForm, Vars0),
    {Vars1, add_bindings(BindingsOrForm, Vars0)}.

%% @doc Same as {@link new_variable/3} with default prefix and suffix.
new_variable(BindingsOrForm) ->
    new_variable(BindingsOrForm, "__Var", "__").

%% @doc Same as {@link new_variable/3} with the given prefix and default
%% suffix.
new_variable(BindingsOrForm, Prefix) ->
    new_variable(BindingsOrForm, Prefix, "").

%% @doc Returns a new variable guaranteed not to be in the given bindings, or
%% the bindings associated with the given form.
%%
%% If given a set of existing bindings, it will return an atom, if given a
%% form it will return a new {@link erl_syntax:variable/1. variable}. That
%% variable will have the {@link erl_anno:generated/1. generated} flag set.
%%
%% The resulting variable will be on the format `Prefix<N>Suffix', where `N'
%% is some small number. Prefix defaults to `__Var', and suffix to `__'.
%%
%% If `TEST' is set during compilation, the numbers will be deterministically
%% increment from 1, otherwise they are random.
%%
%% @see erl_syntax_lib:new_variable_name/1
new_variable(BindingsOrForm, Prefix, Suffix) ->
    Set = get_bindings(BindingsOrForm),
    Name = erl_syntax_lib:new_variable_name(?variable_formatter, Set),
    case
        is_list(BindingsOrForm) orelse
        is_map(BindingsOrForm) orelse
        sets:is_set(BindingsOrForm)
    of
        true ->
            Name;
        false ->
            ?assertIsForm(BindingsOrForm),
            var(BindingsOrForm, Name)
    end.

%% @doc Same as {@link new_variables/4} with default prefix and suffix.
new_variables(Total) when is_integer(Total) ->
    new_variables(sets:new(), Total).

%% @doc Same as {@link new_variables/4} with the given prefix and default
%% suffix.
new_variables(BindingsOrForm, Total) ->
    new_variables(BindingsOrForm, Total, "__Var", "__").

%% @doc Same as {@link new_variables/4} with the given prefix and suffix.
new_variables(BindingsOrForm, Total, Prefix) ->
    new_variables(BindingsOrForm, Total, Prefix, "").

%% @doc Returns `Total' number of new variables like {@link new_variable/3}.
%%
%% @see erl_syntax_lib:new_variable_names/3
new_variables(BindingsOrForm, Total, Prefix, Suffix) ->
    Set = get_bindings(BindingsOrForm),
    Vars = erl_syntax_lib:new_variable_names(
        Total, ?variable_formatter, Set
    ),
    maybe_form(BindingsOrForm, Vars).

%% @private
maybe_form(Bindings, Variables) when is_list(Bindings) ->
    ordsets:from_list(Variables);
maybe_form(BindingsOrForm, Variables) ->
    case sets:is_set(BindingsOrForm) of
        true ->
            Variables;
        false ->
            ?assertIsForm(BindingsOrForm),
            [var(BindingsOrForm, Name) || Name <- Variables]
    end.

%% @private
var(Form, Name) when is_atom(Name) ->
    set_annotation(
        erl_syntax:copy_attrs(Form, erl_syntax:variable(Name)),
        generated,
        true
    );
var(Form, Var) ->
    erl_syntax:copy_attrs(Form, Var).

%% @private
var_name(Name) when is_atom(Name) ->
    Name;
var_name(Form) ->
    erl_syntax:variable_name(Form).

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

%% @doc Adds the given binding to the existing ones.
%% See {@link add_bindings/2}.
-spec add_binding
    (#{bindings := bindings_by_type()}, atom()) -> #{bindings := bindings_by_type()};
    (bindings_by_type(), atom()) -> bindings_by_type();
    (sets:set(Variable), atom()) -> sets:set(Variable) when
        Variable :: variable();
    (ordsets:set(Variable), atom()) -> ordsets:ordset(Variable) when
        Variable :: variable();
    (merlin:ast(), atom()) -> merlin:ast().
add_binding(Bindings, NewBinding) ->
    add_bindings(Bindings, [NewBinding]).

%% @doc Adds the given bindings to the existing ones.
%% Accepts the same input as {@link get_bindings}.
%%
%% When given a form, it updates the bindings on that form, see
%% {@link merlin:annotate/2} for more info.
%% When given a map of bindings as returned by {@link get_bindings_with_type},
%% it updates the `free' and `bound' fields as appropriate.
-spec add_bindings
    (#{bindings := bindings_by_type()}, set()) -> #{bindings := bindings_by_type()};
    (bindings_by_type(), set()) -> bindings_by_type();
    (sets:set(Variable), set()) -> sets:set(Variable) when
        Variable :: variable();
    (ordsets:set(Variable), set()) -> ordsets:ordset(Variable) when
        Variable :: variable();
    (merlin:ast(), set()) -> merlin:ast().
add_bindings(#{bindings := Bindings} = Input, NewBindings) ->
    Input#{ bindings => add_bindings(Bindings, NewBindings) };
add_bindings(#{ env := _Env, bound := Bound0, free := Free0 } = Input, New0) ->
    New1 = into_ordset(New0),
    New2 = lists:map(fun var_name/1, New1),
    Free1 = ordsets:subtract(Free0, New2),
    Bound1 = ordsets:union(Bound0, New2),
    Input#{
        free := Free1,
        bound := Bound1
    };
add_bindings(BindingsOrForm, NewBindings0) ->
    NewBindings1 = into_ordset(NewBindings0),
    NewBindings2 = lists:map(fun var_name/1, NewBindings1),
    case sets:is_set(BindingsOrForm) of
        true ->
            Set = sets:from_list(NewBindings2),
            sets:union(BindingsOrForm, Set);
        false ->
            case ordsets:is_set(BindingsOrForm) of
                true ->
                    ordsets:union(BindingsOrForm, NewBindings2);
                false ->
                    UpdatedBindings = add_bindings(
                        get_annotations(BindingsOrForm), NewBindings2
                    ),
                    if is_map(UpdatedBindings) ->
                        update_annotation(BindingsOrForm, UpdatedBindings);
                    ?else ->
                        set_annotation(BindingsOrForm, bound, UpdatedBindings)
                    end
            end
    end.

%% @private
-spec into_ordset(set(T)) -> ordsets:set(T).
into_ordset(List) when is_list(List) ->
    %% May be unsorted and/or not unique
    ordsets:from_list(List);
into_ordset(Set) ->
    case sets:is_set(Set) of
        true ->
            ordsets:from_list(sets:to_list(Set));
        false ->
            case ordsets:is_set(Set) of
                true ->
                    Set;
                false ->
                    error(badarg)
            end
    end.

%% @private
%% @doc Works like {@link set:is_element/2} and {@link ordset:is_element/2},
%% handling both types of sets.
is_element(Set, Key) ->
    case sets:is_set(Set) of
        true ->
            sets:is_element(Key, Set);
        false ->
            case ordsets:is_set(Set) of
                true ->
                    ordsets:is_element(Key, Set);
                false ->
                    error(badarg)
            end
    end.
