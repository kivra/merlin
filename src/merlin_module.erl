%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Helpers for working with {@link forms(). forms} representing a module.
%%%
%%% They also work with lists of pretty much any {@link merlin:ast(). node}, but
%%% most makes only sense if you have a list of forms representing a module.
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%_* Module declaration =====================================================
-module(merlin_module).

%%%_* Exports ================================================================
%%%_ * API -------------------------------------------------------------------
-export([
    annotate/1,
    annotate/2,
    analyze/1,
    analyze/2,
    export/2,
    file/1,
    find_source/1,
    line/1,
    name/1
]).

%%%_* Types ------------------------------------------------------------------
-export_type([
    forms/0
]).

%%%_* Includes ===============================================================
-include("internal.hrl").
-include("assertions.hrl").
-include("log.hrl").

%%%_* Macros =================================================================

%%%_* Types ==================================================================
-type analysis() :: #{
    attributes := #{
        spec => #{
            %% -spec function_name(...Arguments) -> Return when Guard.
            function_name() := {
                Arguments :: [merlin:ast()],
                Guard :: none | merlin:ast(),
                Return :: merlin:ast()
            }
        },
        type => #{
            %% -type function_name(...TypeArguments) :: Type.
            function_name() := {TypeArguments :: [merlin:ast()], Type :: merlin:ast()}
        },
        opaque => #{
            %% -opaque function_name(...TypeArguments) :: Type.
            function_name() := {TypeArguments :: [merlin:ast()], Type :: merlin:ast()}
        },
        compile => [compile:option()],
        AttributeName :: atom() => AttributeArguments :: [term()]
    },
    exports := ordsets:ordset(extended_function_name()),
    export_types := ordsets:ordset(function_name()),
    file := string(),
    functions := ordsets:ordset(function_name()),
    imports := #{
        module() := ordsets:ordset(extended_function_name())
    },
    module_imports := ordsets:ordset(module()),
    records := #{
        RecordTag ::
            atom() := #{
                Field ::
                    atom() := {
                        Default :: none | merlin:ast(), Type :: none | merlin:ast()
                    }
            }
    },
    module => module(),
    errors => [merlin:ast()],
    warnings => [merlin:ast()]
}.
%% Represents the result of {@link analyze/1} and {@link analyze/2}.

-type function_name() :: {atom(), arity()}.
%% Represents a `FunctionName/Arity' pair.

-type extended_function_name() :: atom() | {atom(), arity()} | {module(), atom()}.
%% Represents a function name as returned by `erl_syntax_lib:analyze_forms/1'.

-type forms() :: [merlin:ast()].
%% Represents a list of forms.
%%
%% That is, a list of {@link merlin:ast(). nodes} that represents top level
%% constructs. For example an attribute (`-module') or a function definition.
%%
%% A good rule of thumb is to think top level stuff that ends with `.'
%% (period).

%%%_* Code ===================================================================
%%%_ * API -------------------------------------------------------------------

%% @equiv annotate(ModuleForms, [bindings, file, resolve_calls, resolve_types])
-spec annotate([merlin:ast()]) -> merlin:parse_transform_return().
annotate(ModuleForms) ->
    annotate(ModuleForms, [bindings, file, resolve_calls, resolve_types]).

%% @doc Annotate the given module {@link merlin:ast(). forms} according to the
%% given options.
%%
%% It always annotates each function definition with a `is_exported'
%% {@link merlin_annotations:get/2. annotation}.
%%
%% <dl>
%% <dt>`bindings'</dt>
%% <dd>See {@link erl_syntax_lib:annotate_bindings/2}</dd>
%% <dt>`compile'</dt>
%% <dd>The analysis contains a `compile' key that merges then given compile
%% options with all `-compile' attributes in `ModuleForms'.
%% See {@link analyze/2}</dd>
%% <dt>`file'</dt>
%% <dd>Each node is annotated with the current file, as determined by the most
%% recent `-file' attribute.</dd>
%% <dt>`resolve_calls'</dt>
%% <dd>Resolves local and remote calls according to the `-import' attributes,
%% if any. For all successfully resolved calls, this sets both a `module' and
%% `is_exported' {@link merlin_annotations:get/2. annotation} on the
%% {@link erl_syntax:application/2. `application'} node.</dd>
%% <dt>`resolve_types'</dt>
%% <dd>Marks exported local types with `is_exported' {@link
%% merlin_annotations:get/2. annotation} on {@link
%% erl_syntax:user_type_application/2. `user_type_application'} nodes.</dd>
%% </dl>
-spec annotate(ModuleForms, Options) -> merlin:parse_transform_return(ModuleForms) when
    ModuleForms :: [merlin:ast()],
    Options :: [Option | {Option, boolean()}],
    Option :: bindings | file | resolve_calls | resolve_types.
annotate(ModuleForms, Options) ->
    State0 = proplists:to_map(Options),
    State1 =
        case proplists:get_value(compile, Options) of
            undefined ->
                State0#{analysis => analyze(ModuleForms)};
            CompileOptions0 ->
                {Analysis0, CompileOptions1} = analyze(ModuleForms, CompileOptions0),
                State0#{
                    analysis => Analysis0,
                    compile_options => CompileOptions1
                }
        end,
    {Result, #{analysis := Analysis1}} = merlin:transform(
        ModuleForms,
        fun annotate_internal/3,
        State1
    ),
    merlin_lib:then(Result, fun(Forms) ->
        [
            case merlin_attributes:is_attribute(Form, module) of
                true ->
                    merlin_annotations:set(Form, analysis, Analysis1);
                false ->
                    Form
            end
         || Form <- Forms
        ]
    end).

%% @doc Similar to `erl_syntax_lib:analyze_forms/1' with some differences noted
%% below.
%%
%% First off it returns maps instead of lists when possible, all fields except
%% `module' are present. The latter is left alone to make it easy to determine
%% if the `module' attribute is missing. There's a couple of extra fields,
%% namely `file' with the value of the first `-file' attribute or `""', and
%% `export_types' as an analogue of `exports' but for `-export_type'.
%%
%% The `attributes' are returned as a map from attribute name to a list of
%% attribute nodes, except for `spec', `type' and `opaque'. These are returned
%% as map from `{Function, Arity}' to a simplified form of their attribute
%% arguments.
%%
%% Finally, unlike {@link erl_syntax_lib:analyze_forms/1}, this guarantees that
%% most lists are sorted and contain no duplicates. This is accomplished by
%% turning them into {@link ordsets:from_list/1. ordsets}.
%%
%% @see analysis()
-spec analyze([merlin:ast()]) -> analysis().
analyze(ModuleForms) ->
    Analysis = maps:from_list(erl_syntax_lib:analyze_forms(ModuleForms)),
    Attributes = attribute_map(Analysis),
    Analysis#{
        attributes => Attributes,
        exports => get_as_ordset(Analysis, exports),
        functions => get_as_ordset(Analysis, functions),
        imports => get_as_map(Analysis, imports),
        %% `module' is taken from Analysis if defined
        records => get_records(Analysis),

        %% Seems unused, at least the docs does not mention carte blanc `-import'
        module_imports => get_as_ordset(Analysis, module_imports),

        %% Not part of the original, but useful to have
        export_types => exported_types(Attributes),
        file => merlin_module:file(ModuleForms)
    }.

%% @doc Same as {@link analyze/1}, but also extracts and appends any inline
%% `-compile' options to the given one.
-spec analyze([merlin:ast()], [compile:option()]) -> {analysis(), [compile:option()]}.
analyze(ModuleForms, Options) when is_list(Options) ->
    Analysis = analyze(ModuleForms),
    CombinedOptions =
        case Analysis of
            #{attributes := #{compile := InlineOptionLists}} when
                is_list(InlineOptionLists)
            ->
                Options ++
                    [
                        InlineOption
                     || InlineOptions <- InlineOptionLists,
                        InlineOption <-
                            if
                                is_list(InlineOptions) -> InlineOptions;
                                true -> [InlineOptions]
                            end
                    ];
            _ ->
                Options
        end,
    {Analysis, CombinedOptions}.

%% @doc Returns the given `Forms' with an `-export' attribute for the given
%% functions.
%%
%% If the `-module' attribute is present in the given `Forms', then the
%% `-export' is inserted just after the `-module'. In addition, if the
%% `-module' attribute form has an `analysis' annotation, i.e. from
%% {@link annotate/2}, then it is used to avoid re-exporting any functions
%% already exported.
%%
%% Otherwise the `-export' is prepended to the given forms.
-spec export(forms(), [{atom(), arity()}]) -> forms().
export(Forms, []) ->
    Forms;
export([], FunctionsToExport) ->
    [export_attribute_for(FunctionsToExport)];
export(Forms, FunctionsToExport0) ->
    case
        lists:splitwith(
            fun(Form) -> not merlin_attributes:is_attribute(Form, module) end, Forms
        )
    of
        {Init, [ModuleForm0 | Tail]} ->
            case merlin_annotations:get(ModuleForm0, analysis, undefined) of
                #{exports := Exported} = Analysis ->
                    ?assert(ordsets:is_set(Exported), "exports must be a set"),
                    FunctionsToExport1 = ordsets:from_list(FunctionsToExport0),
                    FunctionsToExport2 = ordsets:subtract(FunctionsToExport1, Exported),
                    case FunctionsToExport2 of
                        [] ->
                            %% No new functions to export
                            Forms;
                        _ ->
                            ExportAttribute0 = export_attribute_for(FunctionsToExport2),
                            ExportAttribute1 = merlin_annotations:set(
                                ExportAttribute0,
                                line,
                                merlin_annotations:get(ModuleForm0, line) + 1
                            ),
                            ModuleForm1 = merlin_annotations:set(
                                ModuleForm0, analysis, Analysis#{
                                    exports := ordsets:union(
                                        Exported, FunctionsToExport2
                                    )
                                }
                            ),
                            Init ++ [ModuleForm1, ExportAttribute1 | Tail]
                    end;
                _ ->
                    ExportAttribute = export_attribute_for(FunctionsToExport0),
                    Init ++ [ModuleForm0, ExportAttribute | Tail]
            end;
        {Forms, []} ->
            ExportAttribute = export_attribute_for(FunctionsToExport0),
            [ExportAttribute | Forms]
    end.

%% @doc Returns the filename for the first `-file' attribute in `Forms', or
%% `none' if no such attribute is found.
-spec file([merlin:ast()]) -> file:filename().
file(Forms) when is_list(Forms) ->
    case merlin_attributes:find(Forms, file) of
        {ok, [FileNameNode, _LineNode]} ->
            erl_syntax:string_value(FileNameNode);
        {error, notfound} ->
            none
    end.

%% @doc Returns the line number for the first `-file' attribute in `Forms', or
%% `none' if no such attribute is found.
-spec line([merlin:ast()]) -> erl_anno:line().
line(Forms) when is_list(Forms) ->
    case merlin_attributes:find(Forms, file) of
        {ok, [_FileNameNode, LineNode]} ->
            erl_syntax:integer_value(LineNode);
        {error, notfound} ->
            none
    end.

%% @doc Returns the module name for the first `-module' attribute in
%% `Forms', or <code>''</code> if not found.
-spec name([merlin:ast()]) -> module() | ''.
name(Forms) when is_list(Forms) ->
    case merlin_attributes:find(Forms, module) of
        {ok, [ModuleNameNode | _MaybeParameterizedModuleArgumentNode]} ->
            erl_syntax:atom_value(ModuleNameNode);
        {error, notfound} ->
            ''
    end.

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
            case code:ensure_loaded(Module) of
                Result when ?oneof(Result, {module, Module}, {error, embedded}) ->
                    CompileOptions = Module:module_info(compile),
                    proplists:get_value(source, CompileOptions);
                {error, nofile} ->
                    undefined;
                {error, Reason} ->
                    ?raise_error(Reason, [Module], #{cause => {code, ensure_loaded}})
            end;
        Source ->
            Source
    end.

%%%_* Private ----------------------------------------------------------------
%%% Start annotate helpers

%% @private
annotate_internal(enter, Form0, #{analysis := Analysis0} = State0) ->
    Analysis1 =
        case merlin_internal:maybe_get_file_attribute(Form0) of
            false -> Analysis0;
            NewFile -> Analysis0#{file => NewFile}
        end,
    State1 = State0#{analysis := Analysis1},
    Form1 =
        case State1 of
            #{file := true, analysis := #{file := File}} ->
                merlin_annotations:set(Form0, file, File);
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
annotate_form(application, Form, #{
    analysis := Analysis,
    resolve_calls := true
}) ->
    case resolve_application(Form, Analysis) of
        {ok, Module, Name, Arity} ->
            merlin_annotations:merge(Form, #{
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
    Form1 = merlin_annotations:set(
        Form0, is_exported, is_exported(Name, Arity, Analysis)
    ),
    Form2 =
        case Attributes of
            #{spec := #{{Name, Arity} := Spec}} ->
                merlin_annotations:set(Form0, spec, Spec);
            _ ->
                Form1
        end,
    if
        Bindings ->
            Env = merlin_annotations:get(Form2, env, ordsets:new()),
            erl_syntax_lib:annotate_bindings(Form2, Env);
        true ->
            Form2
    end;
annotate_form(_, Form, _) ->
    Form.

%% @private
resolve_application(Node, Analysis) ->
    Operator = erl_syntax:application_operator(Node),
    Arity = length(erl_syntax:application_arguments(Node)),
    case erl_syntax:type(Operator) of
        atom ->
            resolve_local_application(Node, Arity, Analysis);
        module_qualifier ->
            resolve_remote_application(Operator, Arity);
        _ ->
            %% Dynamic value, can't resolve
            dynamic
    end.

%% @private
resolve_remote_application(Operator, Arity) ->
    Module = erl_syntax:module_qualifier_argument(Operator),
    Function = erl_syntax:module_qualifier_body(Operator),
    case {erl_syntax:type(Module), erl_syntax:type(Function)} of
        {atom, atom} ->
            {ok, erl_syntax:atom_value(Module), erl_syntax:atom_value(Function), Arity};
        _ ->
            %% Dynamic value, can't resolve
            dynamic
    end.

%% @private
resolve_local_application(
    Node,
    Arity,
    #{
        functions := Functions,
        imports := Imports
    } = Analysis
) ->
    Operator = erl_syntax:application_operator(Node),
    Name = erl_syntax:atom_value(Operator),
    Function = {Name, Arity},
    case ordsets:is_element(Function, Functions) of
        true ->
            %% Function defined in this module
            case Analysis of
                #{module := CallModule} ->
                    {ok, CallModule, Name, Arity};
                _ ->
                    {warning, "Missing -module, can't resolve local function calls"}
            end;
        false ->
            case
                [
                    CallModule
                 || {CallModule, ImportedFunctions} <- maps:to_list(Imports),
                    ordsets:is_element(Function, ImportedFunctions)
                ]
            of
                [CallModule] ->
                    {ok, CallModule, Name, Arity};
                [] ->
                    %% Assume all other calls refer to builtin functions
                    %% Maybe add a sanity check for compile no_auto_import?
                    {ok, erlang, Name, Arity};
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
    CommaSeperatedList0 = lists:join(", ", List),
    CommaSeperatedList1 = lists:concat(CommaSeperatedList0),
    string:replace(CommaSeperatedList1, ", ", " and ", trailing).

%% @private
is_exported(Name, Arity, #{exports := Exports}) ->
    lists:member({Name, Arity}, Exports).

%%% Start analyze helpers

%% @private
get_as_map(Analysis, Key) ->
    maps:from_list(maps:get(Key, Analysis, [])).

%% @private
get_as_ordset(Analysis, Key) ->
    ordsets:from_list(maps:get(Key, Analysis, [])).

get_records(Analysis) ->
    maps:from_list([
        {RecordTag, maps:from_list(Fields)}
     || {RecordTag, Fields} <- maps:get(records, Analysis, [])
    ]).

%% @private
attribute_map(Analysis) when not is_map_key(attributes, Analysis) ->
    #{};
attribute_map(#{attributes := []}) ->
    #{};
attribute_map(#{attributes := Attributes}) ->
    Groups = lists:foldl(fun pair_grouper/2, #{}, Attributes),
    Groups#{
        spec => get_spec_attributes(Groups),
        type => get_type_attributes(Groups, type),
        opaque => get_type_attributes(Groups, opaque)
    }.

%% @private
pair_grouper({Type, Value}, Groups) ->
    Values = maps:get(Type, Groups, []),
    maps:put(Type, [Value | Values], Groups).

%% @private
get_spec_attributes(Groups) ->
    SpecAttributes = maps:get(spec, Groups, []),
    maps:from_list(lists:map(fun get_spec_attributes_internal/1, SpecAttributes)).

get_spec_attributes_internal({NameArity, Disjunctions}) ->
    {NameArity, [simplify_spec(SpecType) || SpecType <- Disjunctions]}.

simplify_spec(SpecType) ->
    case erl_syntax:type(SpecType) of
        function_type ->
            {
                erl_syntax:function_type_arguments(SpecType),
                none,
                erl_syntax:function_type_return(SpecType)
            };
        constrained_function_type ->
            FunctionType = erl_syntax:constrained_function_type_body(SpecType),
            FunctionConstraint = erl_syntax:constrained_function_type_argument(
                SpecType
            ),
            {
                erl_syntax:function_type_arguments(FunctionType),
                FunctionConstraint,
                erl_syntax:function_type_return(FunctionType)
            }
    end.

%% @private
-spec get_type_attributes(Groups, Kind) -> #{{Name, Arity} := Attribute} when
    Groups :: #{atom() := [Attribute]},
    Kind :: type | opaque,
    Name :: atom(),
    Arity :: arity(),
    Attribute :: erl_syntax:syntaxTree().
get_type_attributes(Groups, Kind) ->
    %% -type limit() :: module:example() becomes
    %% {
    %%     limit,
    %%     {remote_type, 1, [{atom, 1, module}, {atom, 1, example}, []]},
    %%     []
    %% }
    %%
    %% -opaque orddict(A, B) :: list(...) becomes
    %% {
    %%     orddict,
    %%     {type, 1, list, [...]},
    %%     [{var, 1, 'A'}, {var, 1, 'B'}]
    %% }
    maps:from_list([
        {{Name, length(TypeArguments)}, Attribute}
     || {Name, _Type, TypeArguments} = Attribute <- maps:get(Kind, Groups, [])
    ]).

%% @private
exported_types(#{export_type := ExportTypeAttributes}) ->
    ordsets:from_list(lists:flatten(ExportTypeAttributes));
exported_types(#{}) ->
    [].

%% @private
export_attribute_for(FunctionsToExport) ->
    erl_syntax:attribute(erl_syntax:atom(export), [
        erl_syntax:list([
            erl_syntax:arity_qualifier(
                erl_syntax:atom(Function), erl_syntax:integer(Arity)
            )
         || {Function, Arity} <- FunctionsToExport
        ])
    ]).

%%%_* Tests ==================================================================
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-include_lib("syntax_tools/include/merl.hrl").

-define(EXAMPLE_MODULE_SOURCE, [
    "-file(\"example.erl\", 1).",
    "%% Example file",
    "-module(example).",
    "",
    "-file(\"include/example.hrl\", 4).",
    "",
    "-file(\"example.erl\", 6).",
    "",
    "-export([func/1])."
    "",
    "-export_type([return/0])."
    "",
    "-type return() :: term().",
    "",
    "-spec func(Module) -> return() when",
    "   Module :: module().",
    "func(Module) ->",
    "    Module:call(),",
    %%   Local call to builtin function
    "    Pid = self(),"
    %%   Remote call + local call
    "    erlang:is_process_alive(Pid) andalso internal_call(),",
    "    Pid."
    "",
    "-spec internal_call() -> ok.",
    "internal_call() -> ok."
]).

-define(EXAMPLE_MODULE_FORMS, ?Q(?EXAMPLE_MODULE_SOURCE)).

annotate_test_() ->
    maps:to_list(#{
        "no forms" => fun() ->
            ?assertEqual(?Q([]), annotate(?Q([])))
        end,
        "no attributes" => fun() ->
            ?assertMatch([_], annotate([?Q(["func() -> ok."])]))
        end,
        "missing -module" => fun() ->
            ?assertMatch(
                {warning, _Forms, [
                    {warning, [{_File, {_Anno, merlin_error, "Missing -module" ++ _}}]}
                ]},
                annotate(
                    ?Q([
                        "func() -> internal().",
                        "internal() -> ok."
                    ]),
                    [resolve_calls]
                )
            )
        end,
        "imported function" => fun() ->
            ?Q([
                "-import('@_', ['@__'/0]).",
                "func() -> _@_Map(_@@_)."
            ]) = annotate(
                ?Q([
                    "-import(lists, [map/2]).",
                    "func() -> map(fun() -> ok end, [])."
                ]),
                [resolve_calls]
            ),
            ?assertEqual(lists, proplists:get_value(module, erl_syntax:get_ann(Map)))
        end,
        "overlapping imports" => fun() ->
            ?assertMatch(
                {error,
                    [
                        {error, [
                            {_File, {_Anno, merlin_error, "Overlapping -import" ++ _}}
                        ]}
                    ],
                    []},
                annotate(
                    ?Q([
                        "-import(maps, [map/2]).",
                        "-import(lists, [map/2]).",
                        "func() -> map(fun() -> ok end, [])."
                    ]),
                    [resolve_calls]
                )
            )
        end,
        "_" => fun() ->
            Result = annotate(?EXAMPLE_MODULE_FORMS),
            ?pp(Result),
            % ?var(Result),
            % error(nope),
            ok
        end
    }).

export_test_() ->
    maps:to_list(#{
        "empty module forms" => ?_assertMerlEqual(
            ?Q("-export([foo/1])."),
            export([], [{foo, 1}])
        ),
        "empty list of functions to export" => ?_assertMerlEqual(
            ?Q("-module(example)."),
            export(?Q("-module(example)."), [])
        ),
        "new function" => ?_assertMerlEqual(
            ?Q([
                "-module(example).",
                "-export([foo/1]).",
                "bar() -> ok."
            ]),
            export(
                ?Q([
                    "-module(example).",
                    "bar() -> ok."
                ]),
                [{foo, 1}]
            )
        ),
        "forms before -module" => ?_assertMerlEqual(
            ?Q([
                "-file(\"example.erl\", 1).",
                "-module(example).",
                "-export([foo/1]).",
                "bar() -> ok."
            ]),
            export(
                ?Q([
                    "-file(\"example.erl\", 1).",
                    "-module(example).",
                    "bar() -> ok."
                ]),
                [{foo, 1}]
            )
        ),
        "already exported without analysis" => ?_assertMerlEqual(
            ?Q([
                "-module(example).",
                "-export([bar/0]).",
                "-export([bar/0]).",
                "bar() -> ok."
            ]),
            export(
                ?Q([
                    "-module(example).",
                    "-export([bar/0]).",
                    "bar() -> ok."
                ]),
                [{bar, 0}]
            )
        ),
        "with analysis" => begin
            [ModuleForm | Tail] = ?Q([
                "-module(example).",
                "-export([bar/0]).",
                "bar() -> ok."
            ]),
            Analysis = analyze([ModuleForm | Tail]),
            ModuleForms = [erl_syntax:add_ann({analysis, Analysis}, ModuleForm) | Tail],
            maps:to_list(#{
                "already existing" => ?_assertMerlEqual(
                    ?Q([
                        "-module(example).",
                        "-export([bar/0]).",
                        "bar() -> ok."
                    ]),
                    export(ModuleForms, [{bar, 0}])
                ),
                "both new and existing" => ?_assertMerlEqual(
                    ?Q([
                        "-module(example).",
                        "-export([foo/1]).",
                        "-export([bar/0]).",
                        "bar() -> ok."
                    ]),
                    export(ModuleForms, [{bar, 0}, {foo, 1}])
                )
            })
        end,
        "missing module" => ?_assertMerlEqual(
            ?Q([
                "-export([foo/1]).",
                "bar() -> ok.",
                "baz() -> 123."
            ]),
            export(
                ?Q([
                    "bar() -> ok.",
                    "baz() -> 123."
                ]),
                [{foo, 1}]
            )
        )
    }).

file_test_() ->
    maps:to_list(#{
        "when -file exists" => ?_assertEqual(
            "example.erl", file(?EXAMPLE_MODULE_FORMS)
        ),
        "when -file is missing" => ?_assertEqual(
            none, file([?Q("-module(example).")])
        )
    }).

line_test_() ->
    maps:to_list(#{
        "when -file exists" => ?_assertEqual(1, line(?EXAMPLE_MODULE_FORMS)),
        "when -file is missing" => ?_assertEqual(none, line([?Q("-module(example).")]))
    }).

name_test_() ->
    maps:to_list(#{
        "when -module exists" => ?_assertEqual(
            example, name(?EXAMPLE_MODULE_FORMS)
        ),
        "when -module is missing" => ?_assertEqual(
            '', name([?Q("-file(\"example.erl\", 1).")])
        )
    }).

find_source_test_() ->
    SourceFile = filename:absname("_build/test/example/src/example.erl"),
    ok = filelib:ensure_dir(SourceFile),
    Ebin = filename:absname("_build/test/example/ebin"),
    ok = filelib:ensure_path(Ebin),
    true = code:add_path(Ebin),
    maps:to_list(#{
        "with debug_info" => fun() ->
            ok = compile_and_load_example_module(SourceFile, Ebin, [debug_info]),
            ?assertEqual(SourceFile, find_source(example))
        end,
        "without debug_info" => fun() ->
            ok = compile_and_load_example_module(SourceFile, Ebin, []),
            ?assertEqual(SourceFile, find_source(example))
        end,
        "both debug_info and source are missing" => fun() ->
            ok = compile_and_load_example_module(SourceFile, Ebin, []),
            ok = file:delete(SourceFile),
            ?assertEqual(SourceFile, find_source(example))
        end,
        "with debug_info but with source missing" => fun() ->
            ok = compile_and_load_example_module(SourceFile, Ebin, [debug_info]),
            ok = file:delete(SourceFile),
            ?assertEqual(SourceFile, find_source(example))
        end,
        "with debug_info but beam file missing" => fun() ->
            ok = compile_and_load_example_module(SourceFile, Ebin, [debug_info]),
            ok = file:delete(filename:join(Ebin, "example.beam")),
            ?assertEqual(SourceFile, find_source(example))
        end,
        "both debug_info and beam file missing" => fun() ->
            ok = compile_and_load_example_module(SourceFile, Ebin, []),
            ok = file:delete(filename:join(Ebin, "example.beam")),
            ?assertEqual(SourceFile, find_source(example))
        end,
        "without source in module_info and beam file missing" => fun() ->
            ok = compile_and_load_example_module(SourceFile, Ebin, [deterministic]),
            ok = file:delete(filename:join(Ebin, "example.beam")),
            ?assertEqual(undefined, find_source(example))
        end,
        "missing module" => fun() ->
            Module = 'some module that probably won\'t exist',
            ?assertEqual({error, nofile}, code:ensure_loaded(Module)),
            ?assertEqual(undefined, find_source(Module))
        end,
        "bad beam file" =>
            {
                setup,
                fun() ->
                    LoggerConfig = logger:get_primary_config(),
                    logger:update_primary_config(#{level => none}),
                    LoggerConfig
                end,
                fun(LoggerConfig) ->
                    _ = file:delete(filename:join(Ebin, "bad beam module.beam")),
                    logger:set_primary_config(LoggerConfig)
                end,
                fun() ->
                    ?assertEqual(ok, file:write_file(filename:join(Ebin, "bad beam module.beam"), <<"garbage">>)),
                    ?assertError(badfile, find_source('bad beam module'))
                end
            }
    }).

compile_and_load_example_module(SourceFile, Ebin, Options) ->
    ok = file:write_file(SourceFile, lists:join($\n, ?EXAMPLE_MODULE_SOURCE)),
    {ok, example, []} = compile:file(SourceFile, Options ++ [return, {outdir, Ebin}]),
    _ = code:purge(example),
    _ = code:delete(example),
    {module, example} = code:ensure_loaded(example),
    ok.

-endif.
