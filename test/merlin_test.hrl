-ifndef(MERLIN_TEST_HRL).
-define(MERLIN_TEST_HRL, true).

-include("internal.hrl").
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%% Helper macro to allow writing inline source code instead of a string of
%% source code. Its especially nice to not having to escape double quotes.
-define(STRINGIFY(Value), ??Value).

%% Helper macro to merl quote, using ?Q/1, inline code.
%% Multiple are needed as some commas are interpreted as arguments to the
%% macro, while others are ignored. Maybe because they are nested?
%%
%% These use the parser feature of joining string literals, e.g. if you
%% write `"foo" "bar"' it gets parsed as if you had written `"foobar"'.
%%
%% They also append a period to finish the form, as that can't be provided
%% inside a macro call. Doing that would end the macro prematurely.
-define(QUOTE(Form), ?Q(??Form ".")).
-define(QUOTE(Form1, Form2), ?Q(??Form1 "," ??Form2 ".")).
-define(QUOTE(Form1, Form2, Form3), ?Q(??Form1 "," ??Form2 "," ??Form3 ".")).
-define(QUOTE(Form1, Form2, Form3, Form4),
    ?Q(??Form1 "," ??Form2 "," ??Form3 "," ??Form4 ".")
).

%% Helper macro for defining a module, to be used with the ?QUOTE macros
-define(PREPEND_MODULE_FORMS(QuotedForm), [
    ?Q("-file(\"example.erl\", 1)."),
    ?Q("-module(example)."),
    ?Q("-record(state, {form})."),
    QuotedForm
]).

%% @equiv ?quickcheck(RawType, Pattern, Property, [])
-define(quickcheck(RawType, Pattern, Property),
    ?quickcheck(RawType, Pattern, Property, [])
).

%% Checks the given PropEr property and raises an `assertEqual' error if it
%% fails.
%%
%% This is needed to be able to run PropEr tests using EUnit. You can provide
%% a comment for the assertion error inside the `Options'.
%%
%% Essentially the same as ?FORALL(Pattern, RawType, Property) from PropEr.
-define(quickcheck(RawType, Pattern, Property, Options),
    ?__quickcheck(
        RawType, Pattern, Property, merlin_test_helpers:proper_options(Options)
    )
).

%% @equiv ?_quickcheck(RawType, Pattern, Property, [])
-define(_quickcheck(RawType, Pattern, Property),
    ?_quickcheck(RawType, Pattern, Property, [])
).

%% Similar to the ?_assert* macros from EUnit, this returns a test function
%% checking the given PropEr property.
%%
%% @see ?quickcheck/2
-define(_quickcheck(RawType, Pattern, Property, Options), begin
    (fun
        (X__Options, X__EUnitTimeout) when is_integer(X__EUnitTimeout) ->
            {timeout, X__EUnitTimeout,
                {?LINE, fun() ->
                    ?__quickcheck(RawType, Pattern, Property, X__Options)
                end}};
        (X__Options, _) ->
            {?LINE, fun() ->
                ?__quickcheck(RawType, Pattern, Property, X__Options)
            end}
    end)(
        %% merlin_test_helpers:proper_options sets `merlin_eunit_timeout'
        merlin_test_helpers:proper_options(Options),
        erlang:get(merlin_eunit_timeout)
    )
end).

-define(__quickcheck(RawType, Pattern, Property, Options), begin
    erlang:erase('merlin_test:assertion'),
    erlang:put('merlin_test:whenfail', []),
    case
        proper:quickcheck(
            proper:forall(RawType, fun(Pattern) ->
                merlin_test_helpers:eval(fun() -> Property end)
            end),
            Options
        )
    of
        true ->
            ok;
        [X__CounterExample] ->
            case erlang:get('merlin_test:whenfail') of
                X__OnFailures when is_function(hd(X__OnFailures), 0) ->
                    lists:foreach(
                        fun(X__OnFailure) -> X__OnFailure() end,
                        lists:reverse(X__OnFailures)
                    );
                _ ->
                    ok
            end,
            case erlang:get('merlin_test:assertion') of
                {X__Type, X__Info, X__Stacktrace} ->
                    erlang:raise(
                        error,
                        {X__Type, [{counterexample, X__CounterExample} | X__Info]},
                        X__Stacktrace
                    );
                undefined ->
                    erlang:error(
                        {assertMatch, [
                            {module, ?MODULE},
                            {line, ?LINE},
                            {expression, ??RawType},
                            {pattern, ??Pattern " when " ??Property},
                            {value, X__CounterExample}
                            | case lists:keyfind(comment, 1, Options) of
                                {comment, X__Comment} -> [{comment, X__Comment}];
                                false -> []
                            end
                        ]}
                    )
            end;
        {error, Reason} ->
            erlang:error(Reason, [??RawType, ??Pattern " when " ??Property, Options])
    end
end).

-endif.
