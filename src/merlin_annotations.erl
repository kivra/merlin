%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc This module allows for a unified handling of vanilla
%%% {@link erl_anno. annotations} and {@link erl_syntax. user annotations}.
%%%
%%% It maintains the representation of the given syntax node as much as
%%% possible, This means that if you given it a vanilla syntax node and
%%% {@link set/3} an {@link erl_anno} annotation, it will return a vanilla
%%% syntax node with the given annotation.
%%%
%%% However if you either give it an {@link erl_syntax} node or set a
%%% erl_syntax user annotation, it will return an {@link erl_syntax} node.
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%_* Module declaration =====================================================
-module(merlin_annotations).

-compile({no_auto_import, [get/1]}).

%%%_* Exports ================================================================
%%%_ * API -------------------------------------------------------------------
-export([
    delete/2,
    get/1,
    get/2,
    get/3,
    has/2,
    merge/2,
    set/3
]).

-export([
    get_anno/1,
    set_anno/2
]).

%%%_* Types ------------------------------------------------------------------
-export_type([
    erl_annotation/0,
    erl_annotations/0,
    erl_annotation_key/0
]).

%%%_* Includes ===============================================================
-include("internal.hrl").
-include("assertions.hrl").

-ifdef(TEST).
-include("merlin_test.hrl").
-endif.

%%%_* Macros =================================================================

%%%_* Types ==================================================================

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
%% This is also the internal format of {@link erl_anno} if some other
%% annotation than {@link erl_anno:line()} and/or
%% {@link erl_anno:line()} has been set.

-type erl_annotation_key() ::
    line | column | file | generated | location | record | text.
%% The different types of builtin {@link erl_anno. annotations}.

%%%_* Code ===================================================================
%%%_ * API -------------------------------------------------------------------
%% @doc Returns `true' if the given syntax node has the given annotation,
%% `false' otherwise.
-spec has(Node, Key) -> boolean() when
    Node :: merlin:ast(),
    Key :: atom().
has(_Node, line) ->
    true;
has(Node, column) ->
    erl_anno:column(erl_syntax:get_pos(Node)) =/= undefined;
has(Node, file) ->
    erl_anno:file(erl_syntax:get_pos(Node)) =/= undefined;
has(Node, generated) ->
    erl_anno:generated(erl_syntax:get_pos(Node));
has(_Node, location) ->
    true;
has(Node, record) ->
    erl_anno:record(erl_syntax:get_pos(Node));
has(Node, text) ->
    erl_anno:text(erl_syntax:get_pos(Node)) =/= undefined;
has(Node, Key) ->
    Annotations = erl_syntax:get_ann(Node),
    case lists:keyfind(Key, 1, Annotations) of
        {Key, _Value} -> true;
        false -> false
    end.

%% @doc Returns all annotations for the given syntax node.
%%
%% This merges {@link erl_anno} annotations with {@link erl_syntax} user
%% annotations. Notably, it always includes both `line' and `location'.
-spec get(merlin:ast()) ->
    #{
        column => erl_anno:column(),
        file => file:filename(),
        generated => boolean(),
        line := erl_anno:line(),
        location := erl_anno:location(),
        record => boolean(),
        text => string(),
        atom() => term()
    }.
get(Node) ->
    %% erl_anno's internal representation is a two-tuple list if there are
    %% any annotations other than `line' and/or `location'.
    Anno0 = erl_syntax:get_pos(Node),
    AnnoMap1 =
        case erl_anno:generated(Anno0) of
            true ->
                maps:from_list(erl_anno:to_term(Anno0));
            false ->
                Anno1 = erl_anno:set_generated(true, Anno0),
                AnnoMap0 = maps:from_list(erl_anno:to_term(Anno1)),
                maps:remove(generated, AnnoMap0)
        end,
    AnnoMap2 =
        case AnnoMap1 of
            #{location := {Line, Column}} when
                is_integer(Line) andalso is_integer(Column)
            ->
                AnnoMap1#{line => Line, column => Column};
            #{location := Line} when is_integer(Line) ->
                AnnoMap1#{line => Line}
        end,
    Annotations = maps:from_list(erl_syntax:get_ann(Node)),
    maps:merge(AnnoMap2, Annotations).

%% @doc Get the value of the given annotation from the given syntax node.
-spec get(Node, Annotation) -> term() when
    Node :: merlin:ast(),
    Annotation :: atom().
get(Node, line) ->
    erl_anno:line(erl_syntax:get_pos(Node));
get(Node, column) ->
    erl_anno:column(erl_syntax:get_pos(Node));
get(Node, file) ->
    erl_anno:file(erl_syntax:get_pos(Node));
get(Node, generated) ->
    erl_anno:generated(erl_syntax:get_pos(Node));
get(Node, location) ->
    erl_anno:location(erl_syntax:get_pos(Node));
get(Node, record) ->
    erl_anno:record(erl_syntax:get_pos(Node));
get(Node, text) ->
    erl_anno:text(erl_syntax:get_pos(Node));
get(Node, Annotation) ->
    Annotations = erl_syntax:get_ann(Node),
    case lists:keyfind(Annotation, 1, Annotations) of
        {Annotation, Value} -> Value;
        false -> ?raise_error({badkey, Annotation}, [Node, Annotation])
    end.

%% @doc Get the value of the given annotation from the given syntax node.
%% If the annotation is not present, return the given default value.
%%
%% @see get/2
-spec get(Node, Key, Default) -> term() when
    Node :: merlin:ast(),
    Key :: atom(),
    Default :: term().
get(Node, Key, Default) ->
    case has(Node, Key) of
        true -> get(Node, Key);
        false -> Default
    end.

%% @doc Set the given annotation to the given value on the given syntax node.
%%
%% @see erl_anno
%% @see erl_syntax:set_ann/2
%% @see erl_syntax:set_pos/2
-spec set(Node, Key, Value) -> Node when
    Node :: merlin:ast(),
    Key :: atom(),
    Value :: term().
set(Node, line, Line) when is_integer(Line) ->
    Anno0 = erl_syntax:get_pos(Node),
    Anno1 = erl_anno:set_line(Line, Anno0),
    set_anno(Node, Anno1);
set(Node, column, Column) when is_integer(Column) ->
    Anno0 = erl_syntax:get_pos(Node),
    Line = erl_anno:line(Anno0),
    Anno1 = erl_anno:set_location({Line, Column}, Anno0),
    set_anno(Node, Anno1);
set(Node, file, File) when ?is_string(File) ->
    Anno0 = erl_syntax:get_pos(Node),
    Anno1 = erl_anno:set_file(File, Anno0),
    set_anno(Node, Anno1);
set(Node, generated, Generated) when is_boolean(Generated) ->
    Anno0 = erl_syntax:get_pos(Node),
    Anno1 = erl_anno:set_generated(Generated, Anno0),
    set_anno(Node, Anno1);
set(Node, location, Location) ->
    Anno0 = erl_syntax:get_pos(Node),
    Anno1 = erl_anno:set_location(Location, Anno0),
    set_anno(Node, Anno1);
set(Node, record, Record) when is_boolean(Record) ->
    Anno0 = erl_syntax:get_pos(Node),
    Anno1 = erl_anno:set_record(Record, Anno0),
    set_anno(Node, Anno1);
set(Node, text, Text) when is_list(Text) ->
    Anno0 = erl_syntax:get_pos(Node),
    Anno1 = erl_anno:set_text(Text, Anno0),
    set_anno(Node, Anno1);
set(Node, Key, Value) ->
    Annotations0 = erl_syntax:get_ann(Node),
    Annotations1 = lists:keystore(Key, 1, Annotations0, {Key, Value}),
    erl_syntax:set_ann(Node, Annotations1).

%% @doc Returns the given syntax node without the given annotation.
%%
%% You are not allowed to delete `line' or `location'.
-spec delete(Node, Key) -> Node when
    Node :: merlin:ast(),
    Key :: atom().
delete(Node, line) ->
    ?raise_error({badkey, line}, [Node, line]);
delete(Node, location) ->
    ?raise_error({badkey, location}, [Node, location]);
delete(Node, column) ->
    Anno0 = erl_syntax:get_pos(Node),
    case erl_anno:location(Anno0) of
        {Line, Column} when is_integer(Line) andalso is_integer(Column) ->
            Anno1 = erl_anno:set_location(Line, Anno0),
            set_anno(Node, Anno1);
        Line when is_integer(Line) ->
            Node
    end;
delete(Node, Key) ->
    case is_erl_anno(Key) of
        true ->
            %% erl_anno doesn't provide a way to delete an annotation, so we
            %% copy over all _other_ annotations onto a new anno.
            Anno0 = erl_syntax:get_pos(Node),
            Anno1 = erl_anno_with(
                Anno0, ordsets:del_element(Key, [file, generated, record, text])
            ),
            set_anno(Node, Anno1);
        false ->
            Annotations0 = erl_syntax:get_ann(Node),
            %% Delete all annotations with the given key, not just the first
            %% one like lists:keydelete/3 would do.
            Annotations1 = proplists:delete(Key, Annotations0),
            erl_syntax:set_ann(Node, Annotations1)
    end.

%% @doc Returns the given syntax node with its existing annotations merged
%% with the given ones.
-spec merge(Node, erl_annotations() | #{atom() => term()}) -> Node when
    Node :: merlin:ast().
merge(Node, Annotations) when is_map(Annotations) ->
    maps:fold(fun merger/3, Node, Annotations);
merge(Node, Annotations) when is_list(Annotations) ->
    lists:foldl(fun merger/2, Node, Annotations).

%% @private
merger({Key, Value}, Node) ->
    set(Node, Key, Value).

%% @private
merger(Key, Value, Node) ->
    set(Node, Key, Value).

%% @doc Returns the {@link erl_anno. annotation} for the given syntax node.
%%
%% This is just a wrapper around {@link erl_syntax:get_pos/1}, added for
%% completeness.
-spec get_anno(merlin:ast()) -> erl_anno:anno().
get_anno(Node) ->
    erl_syntax:get_pos(Node).

%% @doc Returns the given node with the given {@link erl_anno. annotation}.
%%
%% Similar to {@link erl_syntax:set_pos/2}, but preserves the representation
%% of the given syntax node.
-spec set_anno(Node, erl_anno:anno()) -> Node when
    Node :: merlin:ast().
set_anno(Wrapper0, Anno) when wrapper =:= element(1, Wrapper0) ->
    %% There's a bug in erl_syntax:set_pos/2 where it only sets the
    %% pos/erl_anno on the wrapper record and not on the syntax node. This
    %% causes erl_syntax:revert/1 to ignore any changes to the pos/erl_anno
    %% field.
    ?assertMatch(
        {wrapper, Type, Attr, _Tree} when
            is_atom(Type) andalso is_record(Attr, attr, 4),
        Wrapper0,
        "erl_syntax #wrapper record has changed shape"
    ),
    Wrapper1 = setelement(3, Wrapper0, set_anno(element(3, Wrapper0), Anno)),
    Wrapper2 = erl_syntax:set_pos(Wrapper1, Anno),
    Wrapper2;
set_anno(Node, Anno) when element(1, Node) =:= tree ->
    erl_syntax:set_pos(Node, Anno);
set_anno({error, {_, Module, Reason}}, Anno) ->
    %% See erl_syntax:get_pos/1 and erl_parse:form_info()
    {error, {Anno, Module, Reason}};
set_anno({warning, {_, Module, Reason}}, Anno) ->
    %% See erl_syntax:get_pos/1 and erl_parse:form_info()
    {warning, {Anno, Module, Reason}};
set_anno(Node, Anno) ->
    setelement(2, Node, Anno).

%%%_* Private ----------------------------------------------------------------

%% @doc Returns `true' if the given annotation is one from {@link erl_anno},
%% `false' otherwise.
-dialyzer({nowarn_function, is_erl_anno/1}).
-spec is_erl_anno
    (erl_annotation_key()) -> true;
    (atom()) -> false.
is_erl_anno(line) -> true;
is_erl_anno(column) -> true;
is_erl_anno(file) -> true;
is_erl_anno(generated) -> true;
is_erl_anno(location) -> true;
is_erl_anno(record) -> true;
is_erl_anno(text) -> true;
is_erl_anno(_) -> false.

%% @doc Like @{link maps:with/2}, but for {@link erl_anno. annotations}.
-spec erl_anno_with(Anno, Keys) -> Anno when
    Anno :: erl_anno:anno(),
    Keys :: [file | generated | record | text].
erl_anno_with(Source, Keys) ->
    NewAnno0 = erl_anno:new(erl_anno:location(Source)),
    lists:foldl(
        fun
            (file, NewAnno) ->
                case erl_anno:file(Source) of
                    undefined -> NewAnno;
                    File -> erl_anno:set_file(File, NewAnno)
                end;
            (generated, NewAnno) ->
                case erl_anno:generated(Source) of
                    false -> NewAnno;
                    true -> erl_anno:set_generated(true, NewAnno)
                end;
            (record, NewAnno) ->
                case erl_anno:record(Source) of
                    false -> NewAnno;
                    true -> erl_anno:set_record(true, NewAnno)
                end;
            (text, NewAnno) ->
                case erl_anno:text(Source) of
                    undefined -> NewAnno;
                    Text -> erl_anno:set_text(Text, NewAnno)
                end
        end,
        NewAnno0,
        Keys
    ).

%%%_* Tests ==================================================================
-ifdef(TEST).

-define(ERL_BOOLEAN_ANNOTATIONS, [generated, record]).
-define(ERL_INTEGER_ANNOTATIONS, [line, column]).
-define(ERL_STRING_ANNOTATIONS, [file, text]).
-define(ERL_ANNOTATIONS,
    ?ERL_INTEGER_ANNOTATIONS ++ [location] ++
        ?ERL_BOOLEAN_ANNOTATIONS ++
        ?ERL_STRING_ANNOTATIONS
).

has_test_() ->
    maps:to_list(#{
        "line" => ?_quickcheck(
            annotated_node_type(),
            Node,
            ?assert(has(Node, line))
        ),
        "location" => ?_quickcheck(
            annotated_node_type(),
            Node,
            ?assert(has(Node, location))
        ),
        "column" => ?_quickcheck(
            annotated_node_type(),
            Node,
            case erl_anno:column(erl_syntax:get_pos(Node)) of
                undefined -> ?assertNot(has(Node, column));
                _ -> ?assert(has(Node, column))
            end
        ),
        "file" => ?_quickcheck(
            annotated_node_type(),
            Node,
            case erl_anno:file(erl_syntax:get_pos(Node)) of
                undefined -> ?assertNot(has(Node, file));
                _ -> ?assert(has(Node, file))
            end
        ),
        "text" => ?_quickcheck(
            annotated_node_type(),
            Node,
            case erl_anno:text(erl_syntax:get_pos(Node)) of
                undefined -> ?assertNot(has(Node, text));
                _ -> ?assert(has(Node, text))
            end
        ),
        "record" => ?_quickcheck(
            annotated_node_type(),
            Node,
            case erl_anno:record(erl_syntax:get_pos(Node)) of
                false -> ?assertNot(has(Node, record));
                true -> ?assert(has(Node, record))
            end
        ),
        "generated" => ?_quickcheck(
            annotated_node_type(),
            Node,
            case erl_anno:generated(erl_syntax:get_pos(Node)) of
                false -> ?assertNot(has(Node, generated));
                true -> ?assert(has(Node, generated))
            end
        ),
        "existing user annotation" => ?_quickcheck(
            annotated_node_type(),
            Node0,
            begin
                Node1 = erl_syntax:add_ann({foo, some_value}, Node0),
                ?assert(has(Node1, foo))
            end
        ),
        "missing user annotation" => ?_quickcheck(
            annotated_node_type(),
            Node,
            ?assertNot(has(Node, foo))
        )
    }).

get_single_test_() ->
    LineAnno = erl_anno:new(7),
    FileAnno = erl_anno:set_file(?FILE, LineAnno),
    GeneratedAnno = erl_anno:set_generated(true, FileAnno),
    VariableNode = {var, LineAnno, 'Variable'},
    NodeWithGenerated = {var, GeneratedAnno, 'Variable'},
    NodeWithFile = {var, FileAnno, 'Variable'},
    NodeWithBound = erl_syntax:add_ann({bound, ['Foo']}, VariableNode),
    maps:to_list(#{
        "get line from form with simplest anno" => fun() ->
            ?assertEqual(7, get(VariableNode, line))
        end,
        "get line from form with complex anno" => fun() ->
            ?assertEqual(7, get(NodeWithFile, line))
        end,
        "get file from form without file, must return undefined by default" => fun() ->
            ?assertEqual(undefined, get(VariableNode, file))
        end,
        "get file from form without file must return the given default" => fun() ->
            ?assertEqual(123, get(VariableNode, file, 123))
        end,
        "get file from form with file" => fun() ->
            ?assertEqual(?FILE, get(NodeWithFile, file))
        end,
        "get generated returns a boolean" => fun() ->
            ?assertMatch(
                Generated when is_boolean(Generated), get(NodeWithGenerated, generated)
            )
        end,
        "get bound from form with bound user annotation" => fun() ->
            ?assertEqual(['Foo'], get(NodeWithBound, bound))
        end,
        "get missing annotation raises badkey" => fun() ->
            ?assertError({badkey, foo}, get(VariableNode, foo))
        end
    }) ++
        [
            {
                atom_to_list(Annotation),
                ?_quickcheck(
                    node_type(),
                    Node,
                    ?assertEqual(
                        erl_anno:Annotation(erl_syntax:get_pos(Node)),
                        get(Node, Annotation)
                    )
                )
            }
         || Annotation <- ?ERL_ANNOTATIONS
        ].

get_all_test_() ->
    LineAnno = erl_anno:new(7),
    FileAnno = erl_anno:set_file(?FILE, LineAnno),
    ColumnAnno = erl_anno:set_location({7, 23}, LineAnno),
    GeneratedAnno = erl_anno:set_generated(true, LineAnno),
    Node = {var, FileAnno, 'Variable'},
    NodeWithGenerated = {var, GeneratedAnno, 'Variable'},
    NodeWithColumn = {var, ColumnAnno, 'Variable'},
    NodeWithBound = erl_syntax:add_ann({bound, ['Foo']}, Node),
    maps:to_list(#{
        "with column" => ?_assertEqual(
            #{
                line => 7,
                location => {7, 23},
                column => 23
            },
            get(NodeWithColumn)
        ),
        "with bound" => ?_assertEqual(
            #{
                bound => ['Foo'],
                file => ?FILE,
                line => 7,
                location => 7
            },
            get(NodeWithBound)
        ),
        "with boolean annotation" => ?_assertEqual(
            #{
                generated => true,
                line => 7,
                location => 7
            },
            get(NodeWithGenerated)
        )
    }).

set_test_() ->
    Line = 7,
    Column = 23,
    Location = {Line, Column},
    LineAnno = erl_anno:new(Line),
    FileAnno = erl_anno:set_file(?FILE, LineAnno),
    LocationAnno = erl_anno:set_location(Location, LineAnno),
    VariableNode = {var, LineAnno, 'Variable'},
    NodeWithFile = {var, FileAnno, 'Variable'},
    NodeWithLocation = {var, LocationAnno, 'Variable'},
    NodeWithBound = erl_syntax:add_ann({bound, ['Foo']}, VariableNode),
    NodeWithBoth = erl_syntax:add_ann({bound, ['Foo']}, NodeWithFile),
    maps:to_list(#{
        "set user annotation" => fun() ->
            ?assertEqual(NodeWithBound, set(VariableNode, bound, ['Foo']))
        end,
        "setting an erl_anno annotation does not covert the form to erl_syntax AST" => fun() ->
            ?assertEqual(NodeWithLocation, set(VariableNode, location, Location)),
            ?assertEqual(NodeWithFile, set(VariableNode, file, ?FILE))
        end,
        "set erl_anno on erl_syntax AST" => fun() ->
            ActualNode = set(NodeWithBound, file, ?FILE),
            ?assertEqual(get_sorted_pos(NodeWithBoth), get_sorted_pos(ActualNode)),
            ?assertEqual(get_sorted_ann(NodeWithBoth), get_sorted_ann(ActualNode))
        end,
        "set user annotation on complex erl_anno" => fun() ->
            ActualNode = set(NodeWithFile, bound, ['Foo']),
            ?assertEqual(get_sorted_pos(NodeWithBoth), get_sorted_pos(ActualNode)),
            ?assertEqual(get_sorted_ann(NodeWithBoth), get_sorted_ann(ActualNode))
        end
    }) ++
        [
            ?_quickcheck(
                {node_type(), annotation_type()},
                {Node, {Annotation, Value}},
                begin
                    ExpectedValue =
                        case {Annotation, Value} of
                            {file, ""} -> undefined;
                            _ -> Value
                        end,
                    ?assertEqual(
                        ExpectedValue,
                        erl_anno:Annotation(
                            erl_syntax:get_pos(set(Node, Annotation, Value))
                        )
                    )
                end
            )
        ].

delete_test_() ->
    LineAnno = erl_anno:new(?LINE),
    ComplexAnno = erl_anno:set_text(
        "some text",
        erl_anno:set_record(
            true,
            erl_anno:set_generated(
                true,
                erl_anno:set_file(
                    ?FILE,
                    erl_anno:new({?LINE, 23})
                )
            )
        )
    ),
    VariableNode = {var, LineAnno, 'Variable'},
    VariableWithComplexAnno = {var, ComplexAnno, 'Variable'},
    VariableWithUserAnnotation = erl_syntax:add_ann({bound, ['Foo']}, VariableNode),
    maps:to_list(#{
        "delete user annotation" => fun() ->
            UserAnnotations = erl_syntax:get_ann(
                delete(VariableWithUserAnnotation, bound)
            ),
            ?assertEqual([], UserAnnotations)
        end,
        "delete missing annotation does nothing" => maps:to_list(#{
            "column" => ?_assertEqual(
                VariableNode, delete(VariableNode, column)
            ),
            "generated" => ?_assertEqual(
                VariableNode, delete(VariableNode, generated)
            ),
            "user annotation" => ?_assertEqual(
                VariableWithUserAnnotation, delete(VariableWithUserAnnotation, foo)
            )
        }),
        "delete line raises badkey" => fun() ->
            ?assertError({badkey, line}, delete(VariableWithComplexAnno, line))
        end,
        "delete location raises badkey" => fun() ->
            ?assertError({badkey, location}, delete(VariableWithComplexAnno, location))
        end,
        "delete record" => fun() ->
            Variable = {var, erl_anno:set_record(true, LineAnno), 'Variable'},
            ?assertEqual(
                false,
                erl_anno:record(
                    erl_syntax:get_pos(delete(Variable, record))
                )
            )
        end
    }) ++
        [
            ?_quickcheck(
                annotation_type(),
                {Annotation, _Value},
                case Annotation of
                    line ->
                        ?assertError(
                            {badkey, line}, delete(VariableWithComplexAnno, line)
                        );
                    location ->
                        ?assertError(
                            {badkey, location},
                            delete(VariableWithComplexAnno, location)
                        );
                    _ ->
                        ?assertNotEqual(
                            erl_anno:Annotation(
                                erl_syntax:get_pos(VariableWithComplexAnno)
                            ),
                            erl_anno:Annotation(
                                erl_syntax:get_pos(
                                    delete(VariableWithComplexAnno, Annotation)
                                )
                            )
                        )
                end
            )
        ].

merge_test() ->
    VariableNode = {var, erl_anno:new(7), 'Variable'},
    NodeWithMergedAnnotations0 = merge(VariableNode, #{
        column => 23, is_exported => true
    }),
    NodeWithMergedAnnotations1 = merge(NodeWithMergedAnnotations0, [
        {generated, true}, {is_exported, false}
    ]),
    ?assertEqual(
        [{generated, true}, {location, {7, 23}}],
        get_sorted_pos(NodeWithMergedAnnotations1)
    ),
    ?assertEqual([{is_exported, false}], get_sorted_ann(NodeWithMergedAnnotations1)).

get_anno_test() ->
    VariableNode = {var, erl_anno:new(7), 'Variable'},
    ?assertEqual(erl_anno:new(7), get_anno(VariableNode)).

set_anno_test_() ->
    maps:to_list(#{
        "regular node" => fun() ->
            VariableNode = {var, erl_anno:new(7), 'Variable'},
            ?assertEqual(
                erl_anno:new(8),
                erl_syntax:get_pos(set_anno(VariableNode, erl_anno:new(8)))
            )
        end,
        "error marker" => fun() ->
            ErrorMarker = erl_syntax:revert(
                erl_syntax:error_marker({erl_anno:new(7), erl_lint, "Reason"})
            ),
            ?assertEqual(
                erl_anno:new(8),
                erl_syntax:get_pos(set_anno(ErrorMarker, erl_anno:new(8)))
            )
        end,
        "warning marker" => fun() ->
            WarningMarker = erl_syntax:revert(
                erl_syntax:warning_marker({erl_anno:new(7), erl_lint, "Reason"})
            ),
            ?assertEqual(
                erl_anno:new(8),
                erl_syntax:get_pos(set_anno(WarningMarker, erl_anno:new(8)))
            )
        end
    }).

is_erl_anno_test_() ->
    maps:to_list(#{
        "line" => ?_assert(is_erl_anno(line)),
        "column" => ?_assert(is_erl_anno(column)),
        "file" => ?_assert(is_erl_anno(file)),
        "generated" => ?_assert(is_erl_anno(generated)),
        "location" => ?_assert(is_erl_anno(location)),
        "record" => ?_assert(is_erl_anno(record)),
        "text" => ?_assert(is_erl_anno(text)),
        "foo" => ?_assertNot(is_erl_anno(foo))
    }).

node_type() ->
    ?LET(
        Forms,
        proper_erlang_abstract_code:module(),
        oneof(Forms)
    ).

annotation_type() ->
    oneof(annotation_types()).

annotation_types() ->
    lists:flatten([
        [{Annotation, pos_integer()} || Annotation <- [line, location]],
        {column, default(pos_integer(), undefined)},
        [{Annotation, string()} || Annotation <- ?ERL_STRING_ANNOTATIONS],
        [{Annotation, boolean()} || Annotation <- ?ERL_BOOLEAN_ANNOTATIONS]
    ]).

annotated_node_type() ->
    AnnotationTypes = [default(none, Type) || Type <- annotation_types()],
    ?LET(
        {Node, AnnotationsWithValues},
        {node_type(), AnnotationTypes},
        begin
            Anno0 = erl_syntax:get_pos(Node),
            Anno1 = lists:foldl(
                fun
                    (none, Anno) ->
                        Anno;
                    ({column, undefined}, Anno) ->
                        erl_anno:set_location(erl_anno:line(Anno), Anno);
                    ({column, Column}, Anno) ->
                        erl_anno:set_location({erl_anno:line(Anno), Column}, Anno);
                    ({Annotation, Value}, Anno) ->
                        SetFunction = binary_to_atom(
                            <<"set_", (atom_to_binary(Annotation))/bytes>>
                        ),
                        erl_anno:SetFunction(Value, Anno)
                end,
                Anno0,
                AnnotationsWithValues
            ),
            erl_syntax:set_pos(Node, Anno1)
        end
    ).

get_sorted_pos(Node) ->
    lists:sort(erl_syntax:get_pos(Node)).

get_sorted_ann(Node) ->
    lists:sort(erl_syntax:get_ann(Node)).

-endif.
