%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Helpers for working with attribute forms.
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%_* Module declaration =====================================================
-module(merlin_attributes).

%%%_* Exports ================================================================
%%%_ * API -------------------------------------------------------------------
-export([
    find/2,
    is_attribute/2,
    name/1
]).

%%%_* Types ------------------------------------------------------------------
-export_type([
    attribute/0
]).

%%%_* Includes ===============================================================
-include("assertions.hrl").

%%%_* Macros =================================================================

%%%_* Types ==================================================================

-type attribute() :: merlin:ast().
%% Represents an attribute form.
%%
%% That is, the AST for `-some_attribute(...).'.

%%%_* Code ===================================================================
%%%_ * API -------------------------------------------------------------------
%% @doc Returns `true' if the given `Form' is an attribute with the given name,
%% `false' otherwise.
is_attribute(Form, Name) ->
    erl_syntax:type(Form) == attribute andalso
        erl_syntax:atom_value(erl_syntax:attribute_name(Form)) == Name.

%% @doc Return the name of an attribute form.
-spec name(attribute()) -> atom().
name(Form) ->
    ?assertNodeType(Form, attribute),
    erl_syntax:atom_value(erl_syntax:attribute_name(Form)).

%% @doc Return the arguments for the first attribute form with the given name,
%% or `{error, notfound}' if no such attribute is found.
%%
%% The {@link erl_syntax:get_ann/1. user annotations} are copied over from the
%% attribute node. This is is useful to get the
%% {@link merlin_module:analysis()} for a module.
%%
%% ```
%% AnnotatedForms = merlin_module:annotate(Forms),
%% {ok, ModuleArguments} = merlin_attributes:find(Forms, module),
%% #{module := _} = merlin_annotations:get(ModuleArguments, analysis).
-spec find(Forms, Name) -> {ok, [merlin:ast()]} | {error, notfound} when
    Forms :: [merlin:ast()],
    Name :: atom().
find(Forms, Name) when is_list(Forms) ->
    case merlin_lib:find_by(Forms, fun(Form) -> is_attribute(Form, Name) end) of
        {ok, Attribute} ->
            Arguments0 = erl_syntax:attribute_arguments(Attribute),
            Arguments1 = [
                erl_syntax:copy_ann(Attribute, Argument)
             || Argument <- Arguments0
            ],
            {ok, Arguments1};
        {error, notfound} ->
            {error, notfound}
    end.

%%%_* Private ----------------------------------------------------------------

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

name_test() ->
    ?assertEqual(compile, name(?Q("-compile([])."))).

find_test_() ->
    maps:to_list(#{
        "when -module exists" => fun() ->
            Result = find(?EXAMPLE_MODULE_FORMS, module),
            ?assertMatch({ok, _}, Result),
            {ok, Form} = Result,
            ?assertMerlMatch(?Q("example"), Form)
        end,
        "when -module is missing" => ?_assertEqual(
            {error, notfound}, find([?Q("-file(\"example.erl\", 1).")], module)
        ),
        "user annotations are copied over" => fun() ->
            Forms = [
                ?Q("-file(\"example.erl\", 1)."),
                erl_syntax:add_ann(
                    {analysis, #{module => example}}, ?Q("-module(example).")
                ),
                ?Q("-compile([export_all]).")
            ],
            {ok, [Module]} = find(Forms, module),
            ?assertMatch(
                #{module := _}, merlin_annotations:get(Module, analysis)
            )
        end
    }).

-endif.
