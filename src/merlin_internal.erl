-module(merlin_internal).

-export([
    'DEFINE HYGIENIC MACRO'/5,
    'DEFINE PROCEDURAL MACRO'/5,
    stuff/1
]).

-include_lib("syntax_tools/include/merl.hrl").

'DEFINE HYGIENIC MACRO'(_Arguments, File, Line, Module, _BodySource) ->
    erlang:error({missing_parse_transform, lists:concat([
        "To use hygienic macros you must enable the merlin parse transform. ",
        File, ":", Line, " in ", Module
    ])}).

'DEFINE PROCEDURAL MACRO'(_Arguments, File, Line, Module, _BodySource) ->
    erlang:error({missing_parse_transform, lists:concat([
        "To use hygienic macros you must enable the merlin parse transform. ",
        File, ":", Line, " in ", Module
    ])}).

stuff(Src) ->
    Forms = merl:quote(Src),
    % ?Q("merlin_internal:'DEFINE HYGIENIC MACRO'(_@File, _@Line, _@Module, _@BodySource)") = ?Q([
    %     "merlin_internal:'DEFINE HYGIENIC MACRO'(",
    %     "   file,",
    %     "   123,",
    %     "   merlin_test,",
    %     "   \"inc(X, Y) when Y > 0 -> X + Y\"",
    %     ")"
    % ]),
    % ?Q("merlin_internal:'DEFINE HYGIENIC MACRO'(_@File, _@Line, _@Module, _@BodySource, _@Body)") = Forms,
    case Forms of
        ?Q("merlin_internal:'DEFINE HYGIENIC MACRO'(_@File, _@Line, _@Module, _@BodySource, _@Body)") ->
            io:format("Q: ~p", [#{
                'File' => File,
                'Line' => Line,
                'Module' => Module,
                'BodySource' => BodySource,
                'Body' => Body
            }]);
        _ -> nope
    end
    .