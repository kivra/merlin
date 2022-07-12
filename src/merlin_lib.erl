%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Helpers for working with {@link erl_syntax:syntaxTree/0}.
%%% Similar to {@link erl_syntax_lib}, but with a different set of helpers,
%%% and a preference for returning maps over proplists.
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%_* Module declaration =====================================================
-module(merlin_lib).

%%%_* Exports ================================================================
%%%_ * API -------------------------------------------------------------------
-export([
    file/1,
    module/1,
    module_form/1,
    update_tree/2,
    value/1
]).

-export([
    format_error/1,
    format_error/2
]).

-export([
    into_error_marker/2,
    find_source/1
]).

-export([
    get_annotation/2,
    get_annotation/3,
    get_annotations/1,
    remove_annotation/2,
    set_annotation/3,
    set_annotations/2,
    update_annotations/2
]).

-export([
    get_attribute/3,
    get_attribute_forms/2,
    get_attributes/2
]).

-export([
    add_binding/2,
    add_bindings/2,
    annotate_bindings/1,
    get_binding_type/2,
    get_bindings/1,
    get_bindings_by_type/2,
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

%%%_* Types ------------------------------------------------------------------
-export_type([
    bindings/0,
    bindings_or_form/0
]).

%%%_* Includes ===============================================================
-include("internal.hrl").

%%%_* Macros =================================================================
-define(ERL_ANNO_KEYS, [line, column, file, generated, record, text]).

-define(is_binding_type(Type),
    (Type =:= bound orelse Type =:= env orelse Type =:= free)
).

-ifndef(TEST).
-define(variable_name_formatting_fun(Prefix, Suffix), fun(N) ->
    binary_to_atom(iolist_to_binary(io_lib:format("~s~p~s", [Prefix, N, Suffix])))
end).
-else.
-define(variable_name_formatting_fun(Prefix, Suffix), fun(_N) ->
    test_variable_formatter(Prefix, Suffix)
end).
-endif.

-define(attribute_filter(Name), fun(Node) ->
    erl_syntax:type(Node) == attribute andalso
        value(erl_syntax:attribute_name(Node)) == Name
end).

%%%_* Types ==================================================================

-type variable() :: atom() | merlin:ast().

-type set() :: set(variable()).
%% Represents a {@link set()} of {@link variable(). variables}.

-type set(T) :: sets:set(T) | ordsets:ordset(T).
%% Represents either of the two builtin `set' data structures in OTP.

-type bindings() :: #{
    env := ordsets:set(variable()),
    bound := ordsets:set(variable()),
    free := ordsets:set(variable())
}.
%% Represents the current bindings for a form

%% @see annotate_bindings/1

-type binding_type() :: env | bound | free.
%% Represents the three types of bindings.
%% <dl>
%% <dt>`env'</dt>
%% <dd>Bindings from the surrounding scope, i.e. a `fun''s closure.</dd>
%% <dt>`bound'</dt>
%% <dd>Bindings with value.</dd>
%% <dt>`free'</dt>
%% <dd>Bindings without a value. It's a compile time error to try to access them.</dd>
%% </dl>

-type bindings_or_form() :: bindings() | merlin:ast().
%% @see get_bindings/1

-type erl_syntax_ast() ::
    {tree, any(), any(), any()}
    | {wrapper, any(), any(), any()}.
%% A bit dirty to know about the internal structure like this, but
%% {@link erl_syntax:syntaxTree/0} also includes the vanilla AST and dialyser
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

-type erl_annotation() ::
    {line, erl_anno:line()}
    | {column, erl_anno:column()}
    | {file, file:filename_all()}
    | {generated, boolean()}
    | {location, erl_anno:location()}
    | {record, boolean()}
    | {text, string()}.
%% Reprensent a single builtin {@link erl_anno. annotation property}.

-type erl_annotations() :: [erl_annotation()].
%% Represents a list of {@link erl_annotation(). annotations}.
%%
%% This is also the internal format of {@link erl_anno} once more then
%% {@link erl_anno:line()} and/or {@link erl_anno:line()} has been set.

-type erl_annotation_key() ::
    line | column | file | generated | location | record | text.
%% The different types of builtin {@link erl_anno. annotations}.

%%%_* Code ===================================================================
%%%_ * API -------------------------------------------------------------------

%% @doc Returns the filename for the first `-file' attribute in `Forms', or
%% `""' if not found.
-spec file([merlin:ast()]) -> string().
file(Forms) ->
    case get_attribute(Forms, file, undefined) of
        undefined -> "";
        [FileAttribute, _Line] -> erl_syntax:string_value(FileAttribute)
    end.

%% @doc Returns the module name for the first `-module' attribute in
%% `Forms', or <code>''</code> if not found.
-spec module([merlin:ast()]) -> module() | ''.
module(Forms) ->
    case module_form(Forms) of
        undefined ->
            '';
        ModuleAttribute ->
            [ModuleName | _MaybeParameterizedModuleArgument] =
                erl_syntax:attribute_arguments(ModuleAttribute),
            erl_syntax:atom_value(ModuleName)
    end.

%% @doc Returns the form for the first `-module' attribute in
%% `Forms', or `undefined' if not found.
-spec module_form([merlin:ast()]) -> merlin:ast() | undefined.
module_form(Forms) ->
    case get_attribute_forms(Forms, module) of
        [ModuleAttribute | _] ->
            ModuleAttribute;
        _ ->
            undefined
    end.

%% @doc Updates the given form using the given groups or subtrees of another
%% form.
%%
%% This is a generalisation of {@link erl_syntax:update_tree/2}.
-spec update_tree(merlin:ast(), [[merlin:ast()]] | merlin:ast()) -> merlin:ast().
update_tree(Node, Groups) when is_list(Groups) ->
    erl_syntax:update_tree(Node, Groups);
update_tree(Node, Form) when is_tuple(Form) ->
    ?assertNodeType(Node, ?assertIsForm(Form)),
    erl_syntax:update_tree(Node, erl_syntax:subtrees(Form)).

%% @doc Returns the value of the given literal node as an Erlang term.
%%
%% Raises `{badvalue, Node}' if the given `Node' is not an literal node.
-spec value(merlin:ast()) -> term().
value(Node) ->
    case erl_syntax:is_literal(Node) of
        true ->
            case erl_syntax:type(Node) of
                atom -> erl_syntax:atom_value(Node);
                integer -> erl_syntax:integer_value(Node);
                float -> erl_syntax:float_value(Node);
                char -> erl_syntax:char_value(Node);
                string -> erl_syntax:string_value(Node);
                _ -> error({badvalue, Node})
            end;
        false ->
            error({badvalue, Node})
    end.

%% @doc Callback for formatting error messages from this module
%%
%% @see erl_parse:format_error/1
-spec format_error(term()) -> string().
format_error(Message0) ->
    Message1 =
        case io_lib:deep_char_list(Message0) of
            true ->
                Message0;
            _ ->
                io_lib:format("~tp", [Message0])
        end,
    case re:run(Message1, "^\\d+: (.+)$", [{capture, all_but_first, list}]) of
        {match, [Message2]} -> Message2;
        nomatch -> Message1
    end.

%% @doc Callback for formatting error messages from this module.
%%
%% See <a href="https://www.erlang.org/eeps/eep-0054">EEP 54</a>
-spec format_error(Reason, erlang:stacktrace()) -> ErrorInfo when
    Reason :: term(),
    ErrorInfo :: #{
        pos_integer() | general | reason => string()
    }.
format_error(badarg, [{?MODULE, remove_annotation, [_Form, line], _Location} | _]) ->
    #{2 => "can't remove the line annotation"};
format_error(_, _) ->
    #{}.

%% @doc Returns a
%% <a href="https://erlang.org/doc/man/erl_parse.html#errorinfo">
%% error info</a> with the given reason and location taken from the second
%% argument. If it is a stacktrace, the latter is taken from the first frame.
%% Otherwise it is assumed to be a {@link merlin:ast/0. syntax node} and its
%% location is used.
-spec into_error_marker(Reason, Stacktrace | Node) -> merlin:error_marker() when
    Reason :: term(),
    Stacktrace :: list({module(), atom(), arity(), [{atom(), term()}]}),
    Node :: merlin:ast().
into_error_marker(Reason, [{_Module, _Function, _ArityOrArguments, Location} | _]) ->
    File = keyfind(Location, file, none),
    Line = keyfind(Location, line, 0),
    {error, {File, {Line, ?MODULE, Reason}}};
into_error_marker(Reason, Node) when is_tuple(Node) ->
    File = get_annotation(Node, file, none),
    Position = erl_syntax:get_pos(Node),
    {error, {File, {Position, ?MODULE, Reason}}}.

%% @doc Returns the path to the source for the given module, or `undefined' if
%% it can't be found.
-spec find_source(module()) -> file:filename() | undefined.
find_source(Module) when is_atom(Module) ->
    MaybeSource =
        case code:get_object_code(Module) of
            {Module, _Beam, Beamfile} ->
                case filelib:find_source(Beamfile) of
                    {ok, FoundSource} -> FoundSource;
                    {error, not_found} -> undefined
                end;
            error ->
                undefined
        end,
    case MaybeSource of
        undefined ->
            CompileOptions = Module:module_info(compile),
            proplists:get_value(source, CompileOptions);
        Source ->
            Source
    end.

%% @doc Returns the annotation for the given form,
%% or raises `{badkey, Annotation}' if not found.
-spec get_annotation(merlin:ast(), atom()) -> term().
get_annotation(Form, Annotation) when is_atom(Annotation) ->
    case is_erl_anno(Annotation) of
        true ->
            Anno = erl_syntax:get_pos(Form),
            get_anno(Annotation, Anno);
        false ->
            Annotations = get_annotations(Form),
            maps:get(Annotation, Annotations)
    end.

%% @doc Returns the annotation for the given form,
%% or Default if not found.
-spec get_annotation(merlin:ast(), atom(), Default) -> Default.
get_annotation(Form, Annotation, Default) when is_atom(Annotation) ->
    Annotations = get_annotations(Form),
    maps:get(Annotation, Annotations, Default).

%% @doc Returns all annotations associated with the given `Form' as a map.
-spec get_annotations(merlin:ast()) -> #{atom() := term()}.
get_annotations(Form) ->
    {ErlAnno, ErlSyntax} = get_annotations_internal(Form),
    maps:merge(maps:from_list(ErlAnno), ErlSyntax).

%% @doc Returns the given form without the given annotation.
%%
%% You may not remove the `line', as it must always be present.
%% You may remove annotations that are not present, if which case the original
%% form is returned.
-spec remove_annotation(merlin:ast(), atom()) -> merlin:ast().
remove_annotation(Form, line) ->
    error(badarg, [Form, line], [{error_info, #{}}]);
remove_annotation(Form, Annotation) when is_atom(Annotation) ->
    case is_erl_anno(Annotation) of
        true ->
            ErlAnnotations0 = erl_syntax:get_pos(Form),
            case get_anno(ErlAnnotations0, Annotation) of
                undefined ->
                    %% The annotation to remove is already missing
                    Form;
                _ ->
                    %% There's no remove annotation in erl_anno,
                    %% instead we set all _other_ annotations
                    ErlAnnotations1 = lists:keydelete(Annotation, 1, ErlAnnotations0),
                    set_erl_anno(Form, ErlAnnotations1)
            end;
        false ->
            ErlSyntax0 = erl_syntax:get_ann(Form),
            ErlSyntax1 = lists:keydelete(Annotation, 1, ErlSyntax0),
            erl_syntax:set_ann(Form, ErlSyntax1)
    end.

%% @doc Returns the given form with the given annotation set to the given
%% value.
%% When given an erl_anno annotation and erl_parse form, it returns a erl_parse
%% form, otherwise an erl_syntax form.
-spec set_annotation(merlin:ast(), atom(), term()) -> merlin:ast().
set_annotation(Form, Annotation, Value) ->
    Tuple = {Annotation, Value},
    case is_erl_anno(Annotation) of
        true ->
            Anno0 = erl_syntax:get_pos(Form),
            Anno1 = set_anno(Tuple, Anno0),
            set_pos(Form, Anno1);
        false ->
            ErlSyntax0 = erl_syntax:get_ann(Form),
            ErlSyntax1 = lists:keystore(Annotation, 1, ErlSyntax0, Tuple),
            erl_syntax:set_ann(Form, ErlSyntax1)
    end.

%% @doc Returns the given form with the given annotations.
%%
%% These may be {@link erl_parse} annotations, user annotations, or a mix of
%% both. The given annotations overwrite any already present. To preseve
%% existing ones use {@link update_annotations/2} instead.
-spec set_annotations(merlin:ast(), #{atom() := term()}) -> merlin:ast().
set_annotations(Form0, Annotations) when is_map(Annotations) ->
    {ErlAnnotations, ErlSyntax} = lists:partition(
        fun is_erl_anno/1,
        maps:to_list(Annotations)
    ),
    Form1 = set_erl_anno(Form0, ErlAnnotations),
    case ErlSyntax of
        [] -> Form1;
        _ -> erl_syntax:set_ann(Form1, ErlSyntax)
    end.

%% @doc Returns the given form with the given annotations merged in.
%% It separates {@link erl_anno} annotations from user once, which means if
%% you set `line' or `file', you update the position/location of the form,
%% else you are setting an erl_syntax user annotation.
%%
%% @see erl_anno
%% @see erl_syntax:get_pos/1
%% @see erl_syntax:get_ann/1
-spec update_annotations(merlin:ast(), #{atom() := term()}) -> erl_syntax_ast().
update_annotations(Form0, NewAnnotations) when is_map(NewAnnotations) ->
    {ErlAnnotations, ErlSyntax} = get_annotations_internal(Form0),
    {NewErlAnnotations, NewErlSyntax} = lists:partition(
        fun is_erl_anno/1,
        maps:to_list(NewAnnotations)
    ),
    UpdatedErlSyntax = maps:merge(ErlSyntax, maps:from_list(NewErlSyntax)),
    Form1 = set_erl_anno(Form0, ErlAnnotations ++ NewErlAnnotations),
    Form2 = erl_syntax:set_ann(Form1, maps:to_list(UpdatedErlSyntax)),
    Form2.

%% @doc Returns the argument to the first module attribute with the given
%% name, or Default if not found.
-spec get_attribute(merlin:ast() | [merlin:ast()], atom(), term()) -> term().
get_attribute(Tree, Name, Default) when is_tuple(Tree) ->
    get_attribute(lists:flatten(erl_syntax:subtrees(Tree)), Name, Default);
get_attribute(Tree, Name, Default) ->
    case lists:search(?attribute_filter(Name), Tree) of
        {value, Node} -> erl_syntax:attribute_arguments(Node);
        false -> Default
    end.

%% @doc Returns the arguments to all attributes with the given name in the
%% given list of forms or subtrees of the given form.
%%
%% Returns the empty list if no such attributes are found.
-spec get_attributes(merlin:ast() | [merlin:ast()], atom()) -> term().
get_attributes(Tree, Name) when is_tuple(Tree) ->
    get_attributes(lists:flatten(erl_syntax:subtrees(Tree)), Name);
get_attributes(Tree, Name) ->
    lists:map(
        fun erl_syntax:attribute_arguments/1,
        get_attribute_forms(Tree, Name)
    ).

%% @doc Returns all attributes with the given name in the given list of forms
%% or subtrees of the given form.
-spec get_attribute_forms(merlin:ast() | [merlin:ast()], atom()) -> merlin:ast().
get_attribute_forms(Tree, Name) when is_tuple(Tree) ->
    get_attribute_forms(lists:flatten(erl_syntax:subtrees(Tree)), Name);
get_attribute_forms(Tree, Name) ->
    lists:filter(?attribute_filter(Name), Tree).

%% @doc Adds the given binding to the existing ones.
%% See {@link add_bindings/2}.
-spec add_binding
    (bindings(), variable()) -> bindings();
    (merlin:ast(), variable()) -> erl_syntax_ast().
add_binding(BindingsOrForm, NewBinding) ->
    add_bindings(BindingsOrForm, [NewBinding]).

%% @doc Adds the given bindings to the existing ones.
%% Accepts the same input as {@link get_bindings}.
%%
%% When given a form, it updates the bindings on that form, see
%% {@link merlin:annotate/2} for more info.
%% When given a map of bindings as returned by {@link get_bindings_with_type},
%% it updates the `free' and `bound' fields as appropriate.
-spec add_bindings
    (bindings(), set()) -> bindings();
    (merlin:ast(), set()) -> erl_syntax_ast().
add_bindings(#{env := _, bound := _, free := _} = Bindings, NewBindings) ->
    merge_bindings(Bindings, NewBindings);
add_bindings(Form, NewBindings) when is_tuple(Form) ->
    Bindings0 = get_annotations(Form),
    Bindings1 = maps:merge(#{env => [], bound => [], free => []}, Bindings0),
    Bindings2 = merge_bindings(Bindings1, NewBindings),
    update_annotations(Form, Bindings2).

%% @doc Annotates the given form or forms using
%% {@link erl_syntax_lib:annotate_bindings/2}.
%%
%% If given a form, it returns the same with the annotated bindings.
%% If given a list of forms, a {@link erl_syntax:form_list/1. form list} is
%% returned instead.
%%
%% It tries to find the `env' variables from the given form, or first form if
%% given a list of forms. If none can be found it assumes there's no `env'
%% variables.
-spec annotate_bindings(merlin:ast() | [merlin:ast()]) -> merlin:ast().
annotate_bindings(Forms0) when is_list(Forms0) ->
    Forms1 = lists:flatten(Forms0),
    Env =
        case Forms1 of
            [Form | _] ->
                get_annotation(Form, env, ordsets:new());
            _ ->
                ordsets:new()
        end,
    Tree = erl_syntax:form_list(Forms1),
    erl_syntax_lib:annotate_bindings(Tree, Env);
annotate_bindings(Form) ->
    Env = get_annotation(Form, env, ordsets:new()),
    erl_syntax_lib:annotate_bindings(Form, Env).

%% @doc Get the type of the given binding in the given form.
%% Preferring bound over env over free.
%%
%% @see erl_syntax_lib:annotate_bindings/2
-spec get_binding_type(bindings_or_form(), atom()) -> bound | env | free | unknown.
get_binding_type(#{bound := Bound, env := Env, free := Free}, Name) ->
    case ordsets:is_element(Name, Bound) of
        true ->
            bound;
        false ->
            case ordsets:is_element(Name, Env) of
                true ->
                    env;
                false ->
                    case ordsets:is_element(Name, Free) of
                        true ->
                            free;
                        false ->
                            unknown
                    end
            end
    end;
get_binding_type(Form, Name) when is_tuple(Form) ->
    get_binding_type(get_annotations(Form), Name).

%% @doc Get all bindings for the given value.
%% Can be a set of annotations, see {@link get_annotations/1}, or
%% {@link merlin:ast/0} form from which those annotations are taken.
-spec get_bindings(bindings_or_form()) -> ordsets:ordset(atom()).
get_bindings(#{bound := Bound, env := Env, free := Free}) ->
    lists:map(fun var_name/1, ordsets:union([Env, Bound, Free]));
get_bindings(Form) when is_tuple(Form) ->
    get_bindings(get_annotations(Form)).

%% @doc Returns the bindings associated of the given `Type'
-spec get_bindings_by_type(bindings_or_form(), binding_type()) ->
    ordsets:ordset(atom()).
get_bindings_by_type(Bindings, Type) when
    ?is_binding_type(Type) andalso is_map_key(Type, Bindings)
->
    lists:map(fun var_name/1, maps:get(Type, Bindings));
get_bindings_by_type(BindingsOrForm, Type) when ?is_binding_type(Type) ->
    case sets:is_set(BindingsOrForm) of
        true ->
            error(badarg);
        false ->
            get_bindings_by_type(get_annotations(BindingsOrForm), Type)
    end.

%% @doc Get all bindings associated with the given `Form'.
%%
%% Returns a map from binding name to kind, preferring bound over env over
%% free.
%%
%% @see erl_syntax_lib:annotate_bindings/2
-spec get_bindings_with_type(bindings_or_form()) -> #{variable() := binding_type()}.
get_bindings_with_type(#{bound := Bound, env := Env, free := Free}) ->
    Bindings = ordsets:union([Env, Bound, Free]),
    maps:from_list([
        case ordsets:is_element(Bound, Binding) of
            true ->
                {Binding, bound};
            false ->
                case ordsets:is_element(Env, Binding) of
                    true ->
                        {Binding, env};
                    false ->
                        case ordsets:is_element(Free, Binding) of
                            true ->
                                {Binding, free};
                            false ->
                                error({missing_binding, Binding})
                        end
                end
        end
     || Binding <- Bindings
    ]);
get_bindings_with_type(Form) when is_tuple(Form) ->
    get_bindings_with_type(get_annotations(Form)).

%% @doc Same as {@link add_new_variable/3} with default prefix and suffix.
%%
%% @see new_variable/3
-spec add_new_variable(BindingsOrForm) -> {variable(), BindingsOrForm} when
    BindingsOrForm :: bindings_or_form().
add_new_variable(BindingsOrForm) ->
    Var = new_variable(BindingsOrForm),
    {Var, add_binding(BindingsOrForm, Var)}.

%% @doc Same as {@link add_new_variable/3} with the given prefix and default
%% suffix.
%%
%% @see new_variable/3
-spec add_new_variable(BindingsOrForm, string()) -> {variable(), BindingsOrForm} when
    BindingsOrForm :: bindings_or_form().
add_new_variable(BindingsOrForm, Prefix) ->
    Var = new_variable(BindingsOrForm, Prefix),
    {Var, add_binding(BindingsOrForm, Var)}.

%% @doc Creates a new variable using {@link new_variable/3} and adds it to the
%% given form or bindings.
%%
%% @see new_variable/3
-spec add_new_variable(BindingsOrForm, string(), string()) ->
    {variable(), BindingsOrForm}
when
    BindingsOrForm :: bindings_or_form().
add_new_variable(BindingsOrForm, Prefix, Suffix) ->
    Var = new_variable(BindingsOrForm, Prefix, Suffix),
    {Var, add_binding(BindingsOrForm, Var)}.

%% @doc Same as {@link new_variables/3} with default prefix and suffix.
%%
%% @see new_variable/3
-spec add_new_variables(BindingsOrForm, pos_integer()) ->
    {[variable()], BindingsOrForm}
when
    BindingsOrForm :: bindings_or_form().
add_new_variables(BindingsOrForm, Total) ->
    Vars0 = new_variables(BindingsOrForm, Total),
    Vars1 = maybe_form(BindingsOrForm, Vars0),
    {Vars1, add_bindings(BindingsOrForm, Vars0)}.

%% @doc Same as {@link new_variable/3} with the given prefix and default
%% suffix.
%%
%% @see new_variable/3
-spec add_new_variables(BindingsOrForm, pos_integer(), string()) ->
    {[variable()], BindingsOrForm}
when
    BindingsOrForm :: bindings_or_form().
add_new_variables(BindingsOrForm, Total, Prefix) ->
    Vars0 = new_variables(BindingsOrForm, Total, Prefix),
    Vars1 = maybe_form(BindingsOrForm, Vars0),
    {Vars1, add_bindings(BindingsOrForm, Vars0)}.

%% @doc Creates `Total' number of new variables using {@link new_variables/4}
%% and adds it to the given form or bindings.
%%
%% @see new_variable/3
-spec add_new_variables(BindingsOrForm, pos_integer(), string(), string()) ->
    {[variable()], BindingsOrForm}
when
    BindingsOrForm :: bindings_or_form().
add_new_variables(BindingsOrForm, Total, Prefix, Suffix) ->
    Vars0 = new_variables(BindingsOrForm, Total, Prefix, Suffix),
    Vars1 = maybe_form(BindingsOrForm, Vars0),
    {Vars1, add_bindings(BindingsOrForm, Vars0)}.

%% @doc Same as {@link new_variable/3} with default prefix and suffix.
-spec new_variable(bindings_or_form()) -> variable().
new_variable(BindingsOrForm) ->
    new_variable(BindingsOrForm, "__Var", "__").

%% @doc Same as {@link new_variable/3} with the given prefix and default
%% suffix.
-spec new_variable(bindings_or_form(), string()) -> variable().
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
-spec new_variable(bindings_or_form(), string(), string()) -> variable().
new_variable(BindingsOrForm, Prefix, Suffix) ->
    Set = into_set(BindingsOrForm),
    Name = erl_syntax_lib:new_variable_name(
        ?variable_name_formatting_fun(Prefix, Suffix), Set
    ),
    hd(maybe_form(BindingsOrForm, [Name])).

%% @doc Same as {@link new_variables/4} with default prefix and suffix.
-spec new_variables(pos_integer()) -> ordsets:ordset(variable()).
new_variables(Total) when is_integer(Total) ->
    new_variables(ordsets:new(), Total).

%% @doc Same as {@link new_variables/4} with the given prefix and default
%% suffix.
-spec new_variables(bindings_or_form(), pos_integer()) -> ordsets:ordset(variable()).
new_variables(BindingsOrForm, Total) ->
    new_variables(BindingsOrForm, Total, "__Var", "__").

%% @doc Same as {@link new_variables/4} with the given prefix and suffix.
-spec new_variables(bindings_or_form(), pos_integer(), string()) ->
    ordsets:ordset(variable()).
new_variables(BindingsOrForm, Total, Prefix) ->
    new_variables(BindingsOrForm, Total, Prefix, "").

%% @doc Returns `Total' number of new variables like {@link new_variable/3}.
%%
%% @see erl_syntax_lib:new_variable_names/3
-spec new_variables(bindings_or_form(), pos_integer(), string(), string()) ->
    ordsets:ordset(variable()).
new_variables(BindingsOrForm, Total, Prefix, Suffix) ->
    Set = into_set(BindingsOrForm),
    Vars = erl_syntax_lib:new_variable_names(
        Total, ?variable_name_formatting_fun(Prefix, Suffix), Set
    ),
    maybe_form(BindingsOrForm, Vars).

%%%_* Private ----------------------------------------------------------------

%% @private
%% @doc Like {@link lists:keyfind/3} with a default value.
keyfind(List, Key, Default) ->
    case lists:keyfind(Key, 1, List) of
        {Key, Value} ->
            Value;
        false ->
            case get(Key) of
                undefined -> Default;
                Value -> Value
            end
    end.

%% @private
-spec is_erl_anno
    (erl_annotation()) -> true;
    (erl_annotation_key()) -> true;
    (any()) -> false.
is_erl_anno(line) -> true;
is_erl_anno(column) -> true;
is_erl_anno(file) -> true;
is_erl_anno(generated) -> true;
is_erl_anno(location) -> true;
is_erl_anno(record) -> true;
is_erl_anno(text) -> true;
is_erl_anno({Key, _Value}) when is_atom(Key) -> is_erl_anno(Key);
is_erl_anno(_) -> false.

%% @private
-spec is_erl_syntax
    (erl_syntax_ast()) -> true;
    (erl_parse()) -> false.
is_erl_syntax(Form) when is_tuple(Form) ->
    Type = element(1, Form),
    Type =:= tree orelse Type =:= wrapper.

%% @private
%% @doc Returns all annotations from {@link erl_anno} and {@link erl_syntax}.
get_annotations_internal(Form) ->
    ?assertIsForm(Form),
    Anno = erl_syntax:get_pos(Form),
    ErlAnno = [
        {Name, get_anno(Name, Anno)}
     || Name <- ?ERL_ANNO_KEYS,
        get_anno(Name, Anno) =/= undefined
    ],
    ErlSyntax = maps:from_list(erl_syntax:get_ann(Form)),
    ?assertEqual(
        [],
        ordsets:intersection(
            ?ERL_ANNO_KEYS,
            ordsets:from_list(maps:keys(ErlSyntax))
        ),
        "erl_anno keys must not be saved as erl_syntax annotations"
    ),
    {ErlAnno, ErlSyntax}.

%% @private
%% @doc Returns the given {@link erl_anno. annotation}.
%%
%% @see erl_anno:column/1
%% @see erl_anno:file/1
%% @see erl_anno:generated/1
%% @see erl_anno:line/1
%% @see erl_anno:location/1
%% @see erl_anno:record/1
get_anno(line, Anno) -> erl_anno:line(Anno);
get_anno(column, Anno) -> erl_anno:column(Anno);
get_anno(file, Anno) -> erl_anno:file(Anno);
get_anno(generated, Anno) -> erl_anno:generated(Anno) orelse undefined;
get_anno(location, Anno) -> erl_anno:location(Anno);
get_anno(record, Anno) -> erl_anno:record(Anno) orelse undefined;
get_anno(text, Anno) -> erl_anno:text(Anno);
get_anno(_, _) -> undefined.

%% @private
%% @doc Updates the given {@link erl_anno. annotation}.
%%
%% @see erl_anno:set_column/2
%% @see erl_anno:set_file/2
%% @see erl_anno:set_generated/2
%% @see erl_anno:set_line/2
%% @see erl_anno:set_location/2
%% @see erl_anno:set_record/2
-spec set_anno(erl_annotation(), erl_anno:anno()) -> erl_anno:anno().
set_anno({line, Line}, Anno) when is_integer(Line) ->
    erl_anno:set_line(Line, Anno);
set_anno({column, Column}, Anno) when is_integer(Column) ->
    Line = erl_anno:line(Anno),
    erl_anno:set_location({Line, Column}, Anno);
set_anno({file, File}, Anno) when is_list(File) ->
    erl_anno:set_file(File, Anno);
set_anno({generated, Generated}, Anno) when is_boolean(Generated) ->
    erl_anno:set_generated(Generated, Anno);
set_anno({location, Location}, Anno) ->
    erl_anno:set_location(Location, Anno);
set_anno({record, Record}, Anno) when is_boolean(Record) ->
    erl_anno:set_record(Record, Anno);
set_anno({text, Text}, Anno) when is_list(Text) ->
    erl_anno:set_text(Text, Anno).

%% @private
%% @doc Returns the given `Form' with the given {@link erl_annotations()}.
%%
%% Notably, this allows the caller to <em>remove</em> annotations. This is not
%% possible with the {@link erl_anno} API.
-spec set_erl_anno(merlin:ast(), erl_annotations()) -> erl_syntax_ast().
set_erl_anno(Form, []) ->
    Form;
set_erl_anno(Form, ErlAnnotations) ->
    Anno0 = erl_anno:new(erl_anno:line(erl_syntax:get_pos(Form))),
    Anno1 = lists:foldl(fun set_anno/2, Anno0, ErlAnnotations),
    set_pos(Form, Anno1).

%% @private
%% @doc Returns the given `Form' with the given {@link erl_anno. annotation}.
set_pos(Form, Anno) ->
    case is_erl_syntax(Form) of
        true ->
            erl_syntax:set_pos(Form, Anno);
        false ->
            setelement(2, Form, Anno)
    end.

%% @private
-spec merge_bindings(bindings(), bindings() | ordsets:ordset(atom())) -> bindings().
merge_bindings(
    #{env := Env0, bound := Bound0, free := Free0} = Bindings,
    #{env := NewEnv, bound := NewBound, free := NewFree}
) ->
    Env1 = ordsets:union(Env0, NewEnv),
    Bound1 = ordsets:union(Bound0, NewBound),
    Free1 = ordsets:union(Free0, NewFree),
    Free2 = ordsets:subtract(Free1, Bound1),
    Bindings#{
        env := Env1,
        bound := Bound1,
        free := Free2
    };
merge_bindings(
    #{env := _Env, bound := Bound0, free := Free0} = Bindings,
    NewBindings0
) ->
    NewBindings1 = sets:to_list(into_set(NewBindings0)),
    NewBindings2 = lists:map(fun var_name/1, NewBindings1),
    Free1 = ordsets:subtract(Free0, NewBindings2),
    Bound1 = ordsets:union(Bound0, NewBindings2),
    Bindings#{
        free := Free1,
        bound := Bound1
    }.

%% @private
-spec maybe_form(bindings_or_form(), [atom() | variable()]) -> [variable()].
maybe_form(Bindings, Variables) when
    is_map(Bindings) orelse is_list(Bindings) andalso is_list(Variables)
->
    ordsets:from_list(Variables);
maybe_form(Form, Variables) when is_list(Variables) ->
    ?assertIsForm(Form),
    [var(Form, Name) || Name <- Variables].

%% @private
-spec var(merlin:ast(), variable()) -> merlin:ast().
var(Form, Name) when is_tuple(Form) andalso is_atom(Name) ->
    set_annotation(
        erl_syntax:copy_attrs(Form, erl_syntax:variable(Name)),
        generated,
        true
    );
var(Form, Var) when is_tuple(Form) andalso is_tuple(Var) ->
    ?assertNodeType(Form, variable),
    erl_syntax:copy_attrs(Form, Var).

%% @private
-spec var_name(variable()) -> atom().
var_name(Name) when is_atom(Name) ->
    Name;
var_name(Form) when is_tuple(Form) ->
    erl_syntax:variable_name(Form).

%% @private
into_set(Ordset) when is_list(Ordset) ->
    sets:from_list(Ordset);
into_set(SetOrForm) ->
    case sets:is_set(SetOrForm) of
        true ->
            SetOrForm;
        false ->
            ?assertIsForm(SetOrForm),
            sets:from_list(get_bindings(SetOrForm))
    end.

%%%_* Tests ==================================================================
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-include_lib("syntax_tools/include/merl.hrl").

-define(EXAMPLE_MODULE_SOURCE, [
    "%% Example file",
    "-module(example).",
    "-file(\"example.erl\", 1).",
    "",
    "-file(\"include/example.hrl\", 1)."
]).

-define(EXAMPLE_MODULE_FORMS, ?Q(?EXAMPLE_MODULE_SOURCE)).

%% During testing we ignore the randomly generated N, and use the process
%% dictionary to keep track of the next number. This is to allow writing
%% deterministic tests.
%%
%% It use multiple counters, one per prefix/suffix combination. This makes it
%% much easier to guess what the automatic variable will be.
test_variable_formatter(Prefix0, Suffix0) ->
    Prefix1 = iolist_to_binary(io_lib:format("~s", [Prefix0])),
    Suffix1 = iolist_to_binary(io_lib:format("~s", [Suffix0])),
    Key = {'merlin_lib:variable_counter', Prefix1, Suffix1},
    N =
        case erlang:get(Key) of
            undefined -> 1;
            Number -> Number
        end,
    put(Key, N + 1),
    binary_to_atom(iolist_to_binary(io_lib:format("~s~p~s", [Prefix1, N, Suffix1]))).

file_test() ->
    ?assertEqual("example.erl", file(?EXAMPLE_MODULE_FORMS)).

module_test_() ->
    maps:to_list(#{
        "when -module exists" => ?_assertEqual(example, module(?EXAMPLE_MODULE_FORMS)),
        "when -module is missing" => ?_assertEqual(
            '', module(?Q("-file(\"example.erl\", 1)."))
        )
    }).

module_form_test_() ->
    maps:to_list(#{
        "when -module exists" => ?_assertMerlEqual(
            ?Q("-module(example)."), module_form(?EXAMPLE_MODULE_FORMS)
        ),
        "when -module is missing" => ?_assertEqual(
            undefined, module_form(?Q("-file(\"example.erl\", 1)."))
        )
    }).

update_tree_test_() ->
    Tree = ?Q("1 + 2"),
    FromTree = erl_syntax:infix_expr(
        ?Q("1"),
        erl_syntax:set_ann(erl_syntax:operator('+'), [{custom, "annotation"}]),
        ?Q("2")
    ),
    maps:to_list(#{
        "from syntax tree" => fun() ->
            UpdatedTree = update_tree(Tree, FromTree),
            ?assertEqual(
                [{custom, "annotation"}],
                erl_syntax:get_ann(erl_syntax:infix_expr_operator(UpdatedTree))
            )
        end,
        "from groups" => fun() ->
            Groups = erl_syntax:subtrees(FromTree),
            UpdatedTree = update_tree(Tree, Groups),
            ?assertEqual(
                [{custom, "annotation"}],
                erl_syntax:get_ann(erl_syntax:infix_expr_operator(UpdatedTree))
            )
        end
    }).

value_test_() ->
    maps:to_list(#{
        "atom" => ?_assertEqual(atom, value(?Q("atom"))),
        "integer" => ?_assertEqual(31, value(?Q("31"))),
        "float" => ?_assertEqual(1.618, value(?Q("1.618"))),
        "char" => ?_assertEqual($m, value(?Q("$m"))),
        "string" => ?_assertEqual("foo", value(?Q("\"foo\""))),
        "tuple" => ?_assertError({badvalue, _}, value(?Q("{1, 2}"))),
        "call" => ?_assertError({badvalue, _}, value(?Q("self()")))
    }).

into_error_marker_test_() ->
    %% Without this acrobatics, the Erlang compiler will warn that the
    %% division below will always fail.
    {One, []} = string:to_integer("1"),
    {Zero, []} = string:to_integer("0"),
    maps:to_list(#{
        "from stacktrace" => fun() ->
            try
                One / Zero
            catch
                error:badarith:Stacktrace ->
                    Line = ?LINE - 3,
                    ErrorMarker = into_error_marker(badarith, Stacktrace),
                    ?assertEqual(
                        {error, {?FILE, {Line, ?MODULE, badarith}}}, ErrorMarker
                    )
            end
        end,
        "from syntax node" => maps:to_list(#{
            "without file" => fun() ->
                Node = ?Q("some_term"),
                Line = ?LINE - 1,
                ErrorMarker = into_error_marker(badarith, Node),
                ?assertEqual(
                    {error, {none, {Line, ?MODULE, badarith}}}, ErrorMarker
                )
            end,
            "with file" => fun() ->
                Node0 = ?Q("some_term"),
                Line = ?LINE - 1,
                Node1 = erl_syntax:set_pos(
                    Node0, erl_anno:set_file(?FILE, erl_syntax:get_pos(Node0))
                ),
                ErrorMarker = into_error_marker(badarith, Node1),
                ?assertEqual(
                    {error,
                        {?FILE, {
                            [{file, ?FILE}, {location, Line}], ?MODULE, badarith
                        }}},
                    ErrorMarker
                )
            end
        })
    }).

find_source_test_() ->
    SourceFile = filename:absname("_build/test/example/src/example.erl"),
    ok = filelib:ensure_dir(SourceFile),
    Ebin = filename:absname("_build/test/example/ebin"),
    ok = filelib:ensure_dir(Ebin),
    file:make_dir(Ebin),
    true = code:add_path(Ebin),
    maps:to_list(#{
        "with debug_info" => fun() ->
            compile_and_load_example_module(SourceFile, Ebin, [debug_info]),
            ?assertEqual(SourceFile, find_source(example))
        end,
        "without debug_info" => fun() ->
            compile_and_load_example_module(SourceFile, Ebin, []),
            ?assertEqual(SourceFile, find_source(example))
        end,
        "both debug_info and source are missing" => fun() ->
            compile_and_load_example_module(SourceFile, Ebin, []),
            file:delete(SourceFile),
            ?assertEqual(SourceFile, find_source(example))
        end,
        "with debug_info but with source missing" => fun() ->
            compile_and_load_example_module(SourceFile, Ebin, [debug_info]),
            file:delete(SourceFile),
            ?assertEqual(SourceFile, find_source(example))
        end,
        "with debug_info but beam file missing" => fun() ->
            compile_and_load_example_module(SourceFile, Ebin, [debug_info]),
            file:delete(filename:join(Ebin, "example.beam")),
            ?assertEqual(SourceFile, find_source(example))
        end,
        "both debug_info and beam file missing" => fun() ->
            compile_and_load_example_module(SourceFile, Ebin, []),
            file:delete(filename:join(Ebin, "example.beam")),
            ?assertEqual(SourceFile, find_source(example))
        end,
        "without source in module_info and beam file missing" => fun() ->
            compile_and_load_example_module(SourceFile, Ebin, [deterministic]),
            file:delete(filename:join(Ebin, "example.beam")),
            ?assertEqual(undefined, find_source(example))
        end

    }).

compile_and_load_example_module(SourceFile, Ebin, Options) ->
    ok = file:write_file(SourceFile, lists:join($\n, ?EXAMPLE_MODULE_SOURCE)),
    {ok, example, []} = compile:file(SourceFile, Options ++ [return, {outdir, Ebin}]),
    code:purge(example),
    code:delete(example),
    code:purge(example),
    {module, example} = code:ensure_loaded(example).

get_annotation_test_() ->
    LineAnno = erl_anno:new(7),
    FileAnno = erl_anno:set_file(?FILE, LineAnno),
    Form = {var, LineAnno, 'Variable'},
    FormWithFile = {var, FileAnno, 'Variable'},
    FormWithBound = erl_syntax:add_ann({bound, ['Foo']}, Form),
    maps:to_list(#{
        "get line from form with simplest anno" => fun() ->
            ?assertEqual(7, get_annotation(Form, line))
        end,
        "get line from form with complex anno" => fun() ->
            ?assertEqual(7, get_annotation(FormWithFile, line))
        end,
        "get file from form without file and default must return undefined" => fun() ->
            ?assertEqual(undefined, get_annotation(Form, file))
        end,
        "get file from form without file must return the given default" => fun() ->
            ?assertEqual(123, get_annotation(Form, file, 123))
        end,
        "get file from form with file" => fun() ->
            ?assertEqual(?FILE, get_annotation(FormWithFile, file))
        end,
        "get bound from form with bound user annotation" => fun() ->
            ?assertEqual(['Foo'], get_annotation(FormWithBound, bound))
        end
    }).

get_annotations_test() ->
    LineAnno = erl_anno:new(7),
    FileAnno = erl_anno:set_file(?FILE, LineAnno),
    Form0 = {var, FileAnno, 'Variable'},
    Form1 = erl_syntax:add_ann({bound, ['Foo']}, Form0),
    ExpectedAnnotations = #{
        line => 7,
        file => ?FILE,
        bound => ['Foo']
    },
    ?assertEqual(ExpectedAnnotations, get_annotations(Form1)).

set_annotation_test_() ->
    Line = 7,
    Column = 23,
    Location = {Line, Column},
    LineAnno = erl_anno:new(Line),
    FileAnno = erl_anno:set_file(?FILE, LineAnno),
    LocationAnno = erl_anno:set_location(Location, LineAnno),
    Form = {var, LineAnno, 'Variable'},
    FormWithFile = {var, FileAnno, 'Variable'},
    FormWithLocation = {var, LocationAnno, 'Variable'},
    FormWithBound = erl_syntax:add_ann({bound, ['Foo']}, Form),
    FormWithBoth = erl_syntax:add_ann({bound, ['Foo']}, FormWithFile),
    maps:to_list(#{
        "set user annotation" => fun() ->
            ?assertEqual(FormWithBound, set_annotation(Form, bound, ['Foo']))
        end,
        "setting an erl_anno annotation does not covert the form to erl_syntax AST" => fun() ->
            ?assertEqual(FormWithLocation, set_annotation(Form, location, Location)),
            ?assertEqual(FormWithFile, set_annotation(Form, file, ?FILE))
        end,
        "set erl_anno on erl_syntax AST" => fun() ->
            ActualForm = set_annotation(FormWithBound, file, ?FILE),
            ?assertEqual(get_pos(FormWithBoth), get_pos(ActualForm)),
            ?assertEqual(get_ann(FormWithBoth), get_ann(ActualForm))
        end,
        "set user annotation on complex erl_anno" => fun() ->
            ActualForm = set_annotation(FormWithFile, bound, ['Foo']),
            ?assertEqual(get_pos(FormWithBoth), get_pos(ActualForm)),
            ?assertEqual(get_ann(FormWithBoth), get_ann(ActualForm))
        end
    }).

get_pos(Form) ->
    case erl_syntax:get_pos(Form) of
        Anno when is_list(Anno) -> lists:sort(Anno);
        Anno -> Anno
    end.

get_ann(Form) ->
    lists:sort(erl_syntax:get_ann(Form)).

add_new_variable_test_() ->
    Bindings0 = #{env => ordsets:new(), bound => ordsets:new(), free => ordsets:new()},
    maps:to_list(#{
        "binding" => fun() ->
            Result0 = add_new_variable(Bindings0),
            ?assertMatch(
                {'__Var1__', #{env := [], bound := ['__Var1__'], free := []}}, Result0
            ),
            {_, Bindings1} = Result0,
            Result1 = add_new_variable(Bindings1),
            ?assertMatch(
                {'__Var2__', #{
                    env := [], bound := ['__Var1__', '__Var2__'], free := []
                }},
                Result1
            )
        end
    }).

-endif.
