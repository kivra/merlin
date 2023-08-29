%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Test helpers for `merlin'.
%%%
%%% Mostly {@link proper. PropEr} related.
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%_* Module declaration =====================================================
-module(merlin_test_helpers).

%%%_* Exports ================================================================
%%%_ * API -------------------------------------------------------------------
-export([
    eval/1,
    proper_options/1
]).

%%%_* Types ------------------------------------------------------------------

%%%_* Includes ===============================================================
-include("internal.hrl").

%%%_* Macros =================================================================
-define(DEFAULT_PROPER_OPTIONS, [
    long_result
]).

%%%_* Types ==================================================================

%%%_* Code ===================================================================
%%%_ * API -------------------------------------------------------------------

%% @doc Returns the given options merged with the default.
%%
%% It allows specifying explicit `shrink' and `colors', even though PropEr
%% doesn't.
%%
%% If no `spec_timeout' is given, it is derived from either `ct's current
%% `timetrap' or `eunit's `timeout'.
%%
%% You may also specify some options using OS environmental variables begining
%% with `"PROPER_"'. For example `PROPER_SHRINK' corresponds to `shrink'.
%% Integers may use `"_"' to make them more readable, like in Erlang.
%%
%% The options you can specify as OS environmental variables are:
%% colors, max_shrinks, max_size, numtests, shrinks and spec_timeout.
proper_options(Options) when is_map(Options) ->
    proper_options(proplists:from_map(Options));
proper_options(Options0) ->
    Options1 = Options0 ++ environmental_options() ++ ?DEFAULT_PROPER_OPTIONS,
    Options2 = set_spec_timeout(Options1),
    %% By converting it to a map and back we remove duplicates
    Options3 = proplists:to_map(Options2, [
        %% PropEr only support `noshrink'/`nocolors' as plain atoms (compact
        %% form). So we need to do some finagling to support `shrink` as a
        %% normal boolean proplists property.
        {negations, [
            {shrink, noshrink},
            {colors, nocolors}
        ]},
        {expand, [
            {{noshrink, false}, []},
            {{nocolors, false}, []}
        ]}
    ]),
    Options4 = maps:fold(fun compact_option/3, [], Options3),
    Options4.

%% @doc Used by ?__quickcheck
%%
%% Allows using assertions instead of/together with returning a boolean.
eval(Property) ->
    try Property() of
        true ->
            true;
        false ->
            false;
        ok ->
            true;
        {whenfail, OnFailure, InnerProperty} ->
            erlang:put('merlin_test:whenfail', [
                OnFailure | erlang:get('merlin_test:whenfail')
            ]),
            eval(InnerProperty)
    catch
        error:{AssertType, Info}:Stacktrace when
            is_list(Info) andalso
                ?oneof(
                    AssertType,
                    %% Ordered by what's (assumed to be) most common
                    assertEqual,
                    assertMatch,
                    assertNotEqual,
                    assertNotMatch,
                    assert,
                    assertNot,
                    assertException,
                    assertNotException
                )
        ->
            erlang:put('merlin_test:assertion', {AssertType, Info, Stacktrace}),
            false
    end.

%%%_* Private ----------------------------------------------------------------
%% @private
environmental_options() ->
    [
        case string:split(EnvironmentalVariable, "=") of
            ["PROPER_SHRINK", Value] ->
                {shrink, boolean_environmental_option(Value)};
            ["PROPER_COLORS", Value] ->
                {colors, boolean_environmental_option(Value)};
            ["PROPER_MAX_SHRINKS", Value] ->
                {max_shrinks, integer_environmental_option(Value)};
            ["PROPER_MAX_SIZE", Value] ->
                {max_size, integer_environmental_option(Value)};
            ["PROPER_NUMTESTS", Value] ->
                {numtests, integer_environmental_option(Value)};
            ["PROPER_SPEC_TIMEOUT", Value] ->
                {spec_timeout, integer_environmental_option(Value)};
            [VarName, Value] ->
                error(badarg, [VarName, Value])
        end
     || EnvironmentalVariable <- os:getenv(),
        nomatch =/= string:prefix(EnvironmentalVariable, "PROPER_")
    ].

%% @doc Returns the given environmental variable as a boolean.
%%
%% `"false"' and `"no"' are considered `false', while `"true"', `"yes"', and `""' are
%% considered `true'.
%%
%% They are compared case insensitively.
boolean_environmental_option(Value) ->
    case string:lowercase(Value) of
        "no" -> false;
        "false" -> false;
        "yes" -> true;
        "true" -> true;
        "" -> true;
        _ -> error(badarg, [Value])
    end.

%% @doc Returns the given environmental variable as an integer.
integer_environmental_option(Value0) ->
    Value1 = string:trim(Value0),
    Value2 = string:replace(Value1, "_", "", all),
    Value3 = unicode:characters_to_list(Value2),
    list_to_integer(Value3).

%% @private
%% Returns a resonable spec timeout for the current test runner,
%% aka EUnit or Common Test.
%%
%% The default number of test runs is 100, this is used together with the
%% default timeout for scale. Then it looks at the actual `numtests' and
%% adjusts accordingly.
%%
%% The default EUnit timeout is 5 seconds while for CT it is 30 minutes.
-ifdef(EUNIT).
set_spec_timeout(Options0) ->
    Options1 =
        case proplists:get_value(spec_timeout, Options0) of
            SpecTimeout when is_integer(SpecTimeout) ->
                Options0;
            infinity ->
                %% To be long enough to be considered infinite, but still stop at
                %% some point, let's take the default timeout per _test case_ and
                %% apply it per _propert call_.
                proplist_set(Options0, spec_timeout, 5000);
            undefined ->
                proplist_set(Options0, spec_timeout, round(5000 / 100))
        end,
    %% Used by the ?quickcheck macros
    erlang:put(
        merlin_eunit_timeout,
        round(
            proplists:get_value(numtests, Options0, 100) *
                proplists:get_value(spec_timeout, Options1) / 1000
        )
    ),
    Options1.
-else.
set_spec_timeout(Options) ->
    Numtests = proplists:get_value(numtests, Options, 100),
    case ct:get_timetrap_info() of
        {infinity, {_Scaling, _ScaleValue}} ->
            proplist_set(Options, spec_timeout, infinity);
        {Time, {_Scaling, ScaleValue}} ->
            TimeoutInMilliseconds = round(Time * ScaleValue * 1000),
            SpecScale = TimeoutInMilliseconds / 100,
            SpecTimeout = SpecScale * Numtests,
            %% Try to match the spec timeout, while allowing some time for
            %% setup/cleanup
            ct:timetrap(10 * ScaleValue + SpecTimeout / 1000.0),
            proplist_set(Options, spec_timeout, SpecTimeout);
        undefined ->
            SpecScale = 30 * 60 * 60 * 1000 / 100,
            proplist_set(Options, spec_timeout, SpecScale * Numtests)
    end.
-endif.

%% @private
%% Most boolean properties must be specified as atoms, but not `stop_nodes'
%% for some reason. This handles that correctly.
compact_option(stop_nodes, Value, Options) ->
    [{stop_nodes, Value} | Options];
compact_option(Option, true, Options) ->
    [Option | Options];
compact_option(Option, Value, Options) ->
    [{Option, Value} | Options].

%% @private
proplist_set(Proplist, Key, Value) ->
    lists:keystore(Key, 1, Proplist, {Key, Value}).

%%%_* Tests ==================================================================
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
