%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Extends {@link merl} to allow patterns with `?Q/1' macro arbitrarily
%%% nested, as well as use those patterns directly in function heads.
%%%
%%% It works by transforming the function clauses to a `case', which then
%%% {@link merl} turns into a call to {@link merl:switch/2}. This allows you
%%% to use the power of `merl' matching much more conveniently.
%%%
%%% Here's an example, say you have a function `func':
%%% ```
%%% func(enter, ?Q("_@var"), #{module := State}) ->
%%%     success.
%%% '''
%%%
%%% It becomes something like:
%%% ```
%%% func(Arg1, Arg2, Arg3) ->
%%%     case merlin_quote_transform:switch(
%%%         [Arg1, Arg2, Arg3],
%%%         [
%%%             fun (enter, Var1, #{module := State}) ->
%%%                     case Var1 of
%%%                         ?Q("_@var") ->
%%%                             {ok, success};
%%%                         _ ->
%%%                             continue
%%%                     end
%%%                 (_, _, _) ->
%%%                     continue
%%%             end
%%%         ]
%%%     ) of
%%%         {ok, ValueVar1} -> ValueVar1;
%%%         _ ->
%%%             error(function_clause)
%%%     end.
%%% '''
%%%
%%% Which then merl expands to match `?Q("_@Var") on `Arg2'/`Var1'.
%%%
%%% Another example:
%%% ```
%%% case Foo of
%%%     #state{form=?Q("_@Var = _@Expr") = Form, bindings=Bindings} when
%%%         erl_syntax:type(Var) =:= variable
%%%     ->
%%%         erl_eval:expr(Form, Bindings);
%%%     #state{form=Form} = State when
%%%         erl_syntax:type(Form) =:= variable
%%%     ->
%%%         matches;
%%%     #state{} = State ->
%%%         State
%%% end
%%% '''
%%%
%%% ```
%%% case merlin_quote_transform:switch(
%%%     [Foo],
%%%     [
%%%         fun (#state{form=Form, bindings=Bindings}) ->
%%%                 case Form of
%%%                     ?Q("_@Var = _@Expr") when
%%%                         erl_syntax:type(Var) =:= variable
%%%                     ->
%%%                         erl_eval:expr(Form, Bindings);
%%%                     _ ->
%%%                         continue
%%%                 end;
%%%             (_) ->
%%%                 continue
%%%         end,
%%%         fun (#state{form=Form}) ->
%%%                 case
%%%                     try
%%%                         erl_syntax:type(Form) =:= variable
%%%                     catch _:_ ->
%%%                         false
%%%                     end
%%%                 of
%%%                     true ->
%%%                         matches;
%%%                     false ->
%%%                         continue
%%%                 end;
%%%             (_) ->
%%%                 continue
%%%         end,
%%%         fun (#state{} = State) ->
%%%                 State;
%%%             (_) ->
%%%                 continue
%%%         end
%%%     ]
%%% ) of
%%%     {ok, __ValueVar1} -> __ValueVar1;
%%%     _ ->
%%%         error(function_clause)
%%% end
%%% '''
%%%
%%% Here you can see that we allow extended guards even if the clause does not
%%% have any merl patterns. But we can't just use it as it, so we wrap it in a
%%% `try'/`catch'.
%%%
%%% You might also have noticed that each clause becomes its own `fun'
%%% expression. This is to allow matching in stages, first vanilla Erlang and
%%% then merl, while at the same time avoiding unsafe use of variables between
%%% clauses.
%%%
%%% That design took a long time to settle on, but now it works.
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%_* Module declaration =====================================================
-module(merlin_quote_transform).

%%%_* Behaviours =============================================================
%% -behaviour(parse_transform).

%%%_* Exports ================================================================
%%%_ * Callbacks -------------------------------------------------------------
-export([
    parse_transform/2
]).

%%%_ * API -------------------------------------------------------------------
%% Used internally by the resulting code or macros
-export([
    switch/2
]).

%%%_* Includes ===============================================================
-include_lib("syntax_tools/include/merl.hrl").
-include("assertions.hrl").
-include("log.hrl").

-ifdef(TEST).
-include("merlin_test.hrl").
-endif.

%%%_* Macros =================================================================
-define(ppc(Clauses), begin
    erlang:apply(
        io,
        format,
        tuple_to_list(
            merlin_internal:format_forms(
                {
                    "Case with " ??Clauses " = ",
                    erl_syntax:case_expr({var, ?LINE, '_'}, Clauses)
                }
            )
        )
    ),
    io:nl()
end).

-define(ppc(Argument, Clauses), begin
    erlang:apply(
        io,
        format,
        tuple_to_list(
            merlin_internal:format_forms(
                {
                    "Case with " ??Argument " of " ??Clauses " = ",
                    erl_syntax:case_expr(Argument, Clauses)
                }
            )
        )
    ),
    io:nl()
end).

%%%_* Code ===================================================================
%%%_ * Callbacks -------------------------------------------------------------
parse_transform(Forms, Options) ->
    FinalForms = transform(Forms, Options),
    return(FinalForms, Options).

%%%_ * API -------------------------------------------------------------------
%% @private
%% @doc Runtime function that correctly emulates a `case' statement.
%% It's to be considered an implementation detail even though it is exported.
%% In the event of an exception, it removes all stack frames from this module,
%% thus making this almost transparent to the user. The only gotcha is that
%% this reduces the stacktrace a bit, but should not be an issue in practice.
-spec switch(Arguments, Clauses) -> Value when
    Arguments :: [term()],
    Clauses :: [fun((Arguments) -> {ok, Value} | continue)].
switch(Arguments, []) when is_list(Arguments) ->
    nomatch;
switch(Arguments, [Clause | Clauses]) when
    is_list(Arguments) andalso is_function(Clause, length(Arguments))
->
    try apply(Clause, Arguments) of
        {ok, Value} ->
            {ok, Value};
        continue ->
            switch(Arguments, Clauses)
    catch
        Class:Reason:Stacktrace0 ->
            Stacktrace1 = [
                Frame
             || {Module, _, _, _} = Frame <- Stacktrace0, Module =/= ?MODULE
            ],
            erlang:raise(Class, Reason, Stacktrace1)
    end.

%%%_* Private ----------------------------------------------------------------
%% @private
%% @doc Does most of the work of this parse_transform, except calling
%% {@link merl_transform:parse_transform/2}.
%%
%% This is to allows easier testing.
-spec transform(Forms, Options) -> FinalForms when
    Forms :: [merlin:ast()],
    Options :: [compile:option()],
    FinalForms :: [merlin:ast()].
transform([], _Options) ->
    [];
transform(Forms, Options) ->
    AnnotatedForms = merlin_module:annotate(Forms, [file, bindings]),
    {FinalForms, _FinalState} = merlin:transform(
        AnnotatedForms,
        fun quote/3,
        #{
            options => Options,
            module => merlin_module:name(Forms)
        }
    ),
    FinalForms.

%% @doc Transforms functions with merl clauses to cases, and then those to
%% {@link merlin_quote_transform:switch/2} calls. See the module documentation
%% for details.
quote(enter, Form, #{module := Module}) ->
    case Form of
        ?Q("'@Name'(_@Args) when _@__@Guard -> _@_@Clauses0.") when
            has_any_clause_with_quote_pattern(Clauses0)
        ->
            %% Move the function clauses into a `case'.
            Arity = erl_syntax:function_arity(Form),
            ?info(
                "Detected quote pattern in ~s:~s/~p",
                [Module, merlin_lib:value(Name), Arity]
            ),
            %% Silence unused variable warning if the logging above is disabled
            _ = Module,
            {CaseArgument0, VariableOrVariables} = merlin_bindings:new(Form, #{
                total => Arity,
                format => "arg@~p"
            }),
            {CaseArgument3, Variables} =
                case Arity of
                    1 ->
                        {VariableOrVariables, [VariableOrVariables]};
                    _ ->
                        CaseArgument1 = erl_syntax:list(VariableOrVariables),
                        CaseArgument2 = erl_syntax:copy_attrs(
                            CaseArgument0, CaseArgument1
                        ),
                        {CaseArgument2, VariableOrVariables}
                end,
            CaseArgument4 = merlin_annotations:set(
                CaseArgument3,
                function_arguments,
                Variables
            ),
            Clauses1 = lists:map(
                fun function_clause_to_case_clause/1,
                Clauses0
            ),
            ?Q([
                "'@Name'(_@Variables) ->",
                "   case _@CaseArgument4 of",
                "       _@_ ->",
                "           _@_Clauses1",
                "   end."
            ]);
        ?Q([
            "case _@CaseArgument0 of",
            "   _@_ ->",
            "       _@_@Clauses0",
            "end"
        ]) when has_complex_merl_patterns(Clauses0) ->
            Arguments = erl_syntax:list(
                merlin_annotations:get(
                    CaseArgument0,
                    function_arguments,
                    [CaseArgument0]
                )
            ),
            {CaseArgument1, ValueVar} = merlin_bindings:new(
                CaseArgument0, "value_var@~p"
            ),
            RaiseFunctionOrCaseClause = raise_function_or_case_clause(
                CaseArgument1
            ),
            Clauses1 = clauses_to_fun(Clauses0),
            ?Q([
                "case " ?MODULE_STRING ":switch(_@Arguments, _@Clauses1) of",
                "    {ok, _@ValueVar} ->",
                "        _@ValueVar;",
                "    _ ->",
                "        _@RaiseFunctionOrCaseClause",
                "end"
            ]);
        ?Q("{'MERLIN QUOTE MARKER', _@FileNode, _@LineNode, _@BodySource}") ->
            %% -define(Q(Text), merl:quote(?LINE, Text)).
            ?Q("merl:quote(_@LineNode, _@BodySource)");
        _ ->
            continue
    end;
quote(_, _, _) ->
    continue.

%% @doc Is the given node the match all pattern, aka underscore?
is_underscore(Node) ->
    erl_syntax:type(Node) =:= underscore.

%% @doc Is the given node a variable/binding?
is_variable(Node) ->
    erl_syntax:type(Node) =:= variable.

%% @doc Will the given `Clause' always match?
%%
%% This is true iff there's no guard and all patterns consists solely of `_'
%% or variables.
will_always_match(Clause) ->
    ?assertNodeType(Clause, clause),
    erl_syntax:clause_guard(Clause) =:= none andalso
        lists:all(
            fun(Pattern) ->
                Type = erl_syntax:type(Pattern),
                Type =:= underscore orelse Type =:= variable
            end,
            erl_syntax:clause_patterns(Clause)
        ).

%% @doc Does the given `Pattern' refer to an unbound variable?
%% The bindings are taken from the second argument.
%%
%% @see merlin_bindings:annotate/1
is_unbound_variable(Pattern, Forms) when is_list(Forms) ->
    is_unbound_variable(Pattern, erl_syntax:form_list(Forms));
is_unbound_variable(Pattern, Form0) ->
    case erl_syntax:type(Pattern) of
        variable ->
            Form1 = merlin_bindings:annotate(Form0),
            Name = erl_syntax:variable_name(Pattern),
            merlin_bindings:has(Form1, Name, free);
        _ ->
            false
    end.

%% @doc Is the given guard a valid guard expression?
%%
%% It also accepts empty guards, since this is used to determine if the guard
%% can be attached to a clause, or if it needs to be handled with a `try'
%% statement.
is_guard_test(none) ->
    %% No guard is ok
    true;
is_guard_test(Guard) ->
    erl_lint:is_guard_test(merlin:revert(Guard)).

%% @doc Is the given `Pattern' a {@link merl} pattern?
%% That is, is it the result of `?Q/1' from either this module,
%% or `merl' itself.
is_merl_quote(Pattern) ->
    case Pattern of
        ?Q("{'MERLIN QUOTE MARKER', _@@_}") -> true;
        ?Q("merl:quote(_@@_)") -> true;
        _ -> false
    end.

%% @doc Does any of the given `Patterns' contain a
%% {@link is_merl_pattern/1. merl pattern}?
%% This checks for nested merl patterns as well as top-level.
has_quote_pattern(Patterns) ->
    case merlin_lib:deep_find_by(Patterns, fun is_merl_quote/1) of
        {ok, _} -> true;
        {error, notfound} -> false
    end.

%% @doc Does any of the given `Clauses' {@link has_quote_pattern/1. contain}
%% a {@link is_merl_pattern/1. merl pattern}?
has_any_clause_with_quote_pattern(Clauses) when is_list(Clauses) ->
    lists:any(
        fun(Clause) ->
            ?assertNodeType(Clause, clause),
            lists:any(
                fun has_quote_pattern/1,
                erl_syntax:clause_patterns(Clause)
            )
        end,
        Clauses
    ).

%% @doc Does any of the given `Clauses' have complex merl patterns?
%%
%% By complex we mean either mixed vanilla and merl patterns, or nested merl
%% patterns. Basically anything that can't be handled by
%% {@link merl:switch/2} alone.
has_complex_merl_patterns(Clauses) when is_list(Clauses) ->
    case is_merl_switchable(Clauses) of
        true ->
            %% Only simple or directly merl:switch/2 compatible clauses
            false;
        false ->
            has_any_clause_with_quote_pattern(Clauses)
    end.

%% @doc Can the given `Clauses' be directly used by {@link merl:switch/2}?
is_merl_switchable([Clause]) ->
    case erl_syntax:clause_patterns(Clause) of
        [Pattern] ->
            is_underscore(Pattern) orelse is_merl_quote(Pattern);
        _ ->
            false
    end;
is_merl_switchable([Clause | Clauses]) ->
    case erl_syntax:clause_patterns(Clause) of
        [Pattern] ->
            case is_merl_quote(Pattern) of
                true ->
                    is_merl_switchable(Clauses);
                false ->
                    false
            end;
        _ ->
            false
    end.

%% @doc Converts functions clauses, that may have multiple patterns, to case
%% clauses that may only have one pattern.
%%
%% It also marks these clauses with the `function_clause' annotation for
%% {@link clause_to_fun/1}.
function_clause_to_case_clause(Clause0) ->
    case erl_syntax:clause_patterns(Clause0) of
        [_SinglePattern] ->
            Clause0;
        Patterns ->
            UnifiedPattern = erl_syntax:list(Patterns),
            Clause1 = update_clause(Clause0, [UnifiedPattern]),
            merlin_annotations:set(Clause1, function_clause, true)
    end.

%% @doc Returns a {@link erl_syntax:list/1. list node} with the result of
%% mapping {@link clause_to_fun/1} over the given `Clauses'.
clauses_to_fun(Clauses) ->
    erl_syntax:list(lists:map(fun clause_to_fun/1, Clauses)).

%% @doc The main workhorse, see the module docs for more info on what it does.
clause_to_fun(Clause0) ->
    [CasePattern] = erl_syntax:clause_patterns(Clause0),
    Guard = erl_syntax:clause_guard(Clause0),
    Body0 = erl_syntax:clause_body(Clause0),
    Body1 = ok_tuple(Body0),
    Clause1 = update_clause(Clause0, copy, copy, Body1),
    Clause2 =
        case merlin_annotations:get(Clause1, function_clause, false) of
            true ->
                %% Pattern is the list of patterns from the original function head
                update_clause(Clause1, erl_syntax:list_elements(CasePattern));
            false ->
                Clause1
        end,
    Patterns = erl_syntax:clause_patterns(Clause2),
    Clause4 =
        case has_quote_pattern(Patterns) of
            true ->
                {
                    Clause3,
                    PatternsWithoutMerl,
                    Replacements
                } = replace_merl_with_temporary_variables(Clause2, Patterns),
                MerlPatternsCase = fold_merl_patterns(Replacements, Guard, Body1),
                update_clause(
                    Clause3,
                    PatternsWithoutMerl,
                    none,
                    MerlPatternsCase
                );
            false ->
                Clause2
        end,
    Guard1 = erl_syntax:clause_guard(Clause4),
    case is_guard_test(Guard1) of
        true ->
            %% Normal Erlang guard
            case will_always_match(Clause4) of
                true ->
                    erl_syntax:fun_expr([Clause4]);
                false ->
                    erl_syntax:fun_expr([
                        Clause4,
                        update_clause(Clause2, underscore, ?Q("continue"))
                    ])
            end;
        false ->
            %% Merl guard
            Body2 = erl_syntax:clause_body(Clause4),
            GuardPattern = join(
                'orelse',
                [
                    join('andalso', Conjunctions)
                 || Conjunctions <- guard_to_nested_lists(Guard1)
                ]
            ),
            GuardedCase = ?Q([
                "case",
                "   try",
                "       _@GuardPattern",
                "   catch",
                "       _:_ ->",
                "           false",
                "   end",
                "of",
                "   true ->",
                "       _@Body2;",
                "   _ ->",
                "       continue",
                "end"
            ]),
            erl_syntax:fun_expr([
                update_clause(Clause4, copy, none, GuardedCase),
                update_clause(Clause2, underscore, ?Q("continue"))
            ])
    end.

%% @doc Nest the given merl pattern/temporary variable pairs into cases.
%% The guard, if any, is attached to the innermost merl pattern/case, allowing
%% it access to variables bound in all cases.
%%
%% In the resulting cases, if any merl pattern won't match, `continue' is
%% returned instead. It is up to the caller to wrap the body in a `{ok, _}'
%% tuple.
%%
%% It tries to avoid useless cases, assigning variables directly, and avoiding
%% `_' patterns entirely.
fold_merl_patterns([{MerlPattern, TemporaryVariable}], Guard, Body) ->
    case_or_match(
        TemporaryVariable,
        MerlPattern,
        Guard,
        Body,
        ?Q("continue")
    );
fold_merl_patterns([{MerlPattern, TemporaryVariable} | Replacements], Guard, Body0) ->
    NestedMerlPatternCases = fold_merl_patterns(Replacements, Guard, Body0),
    case_or_match(
        TemporaryVariable,
        MerlPattern,
        Guard,
        NestedMerlPatternCases,
        ?Q("continue")
    ).

%% @doc Returns the given node, or nodes, wrapped in a `{ok, Node}' tuple.
%%
%% If given a list of nodes, they are additionally wrapped in a
%% `begin Nodes end'.
ok_tuple([Node]) ->
    ?Q("{ok, _@Node}");
ok_tuple(Nodes) when is_list(Nodes) ->
    ?Q("{ok, begin _@Nodes end}").

%% @doc Returns the given `Pattern' matched against the given `Argument',
%% followed by the given `Body'.
%% If it's a simple match against a variable, then it becomes a simple
%% `Pattern = Argument' match, otherwise a `case'.
case_or_match(Argument, Pattern, none, MatchBody, NoMatchBody) ->
    case is_underscore(Pattern) of
        true ->
            MatchBody;
        false ->
            case is_unbound_variable(Pattern, MatchBody) of
                true ->
                    ?Q([
                        "_@Pattern = _@Argument,",
                        "_@MatchBody"
                    ]);
                false ->
                    case_maybe_with_no_match_clause(
                        Argument,
                        Pattern,
                        none,
                        MatchBody,
                        NoMatchBody
                    )
            end
    end;
case_or_match(Argument, Pattern, Guard, MatchBody, NoMatchBody) ->
    case_maybe_with_no_match_clause(
        Argument,
        Pattern,
        Guard,
        MatchBody,
        NoMatchBody
    ).

%% @private
case_maybe_with_no_match_clause(Argument, Pattern, Guard, MatchBody0, NoMatchBody0) ->
    MatchBody1 = maybe_wrap_in_list(MatchBody0),
    NoMatchBody1 = maybe_wrap_in_list(NoMatchBody0),
    ?Q([
        "case _@Argument of",
        "    _@Pattern when _@__Guard ->",
        "        _@MatchBody1;",
        "    _ ->",
        "        _@NoMatchBody1",
        "end"
    ]).

%% @doc Normalizes the given `Guard' to a list of lists, representing a list
%% of disjunctions, each a list of conjunctions.
guard_to_nested_lists(Guard) ->
    Disjunction =
        case erl_syntax:type(Guard) of
            disjunction -> erl_syntax:disjunction_body(Guard);
            conjunction -> [Guard]
        end,
    lists:map(fun erl_syntax:conjunction_body/1, Disjunction).

%% @doc Joins the given `Expressions' using the given `Operator'.
join(_, [Expression]) ->
    Expression;
join(OperatorName, [First | Expressions]) ->
    Operator = erl_syntax:operator(OperatorName),
    lists:foldl(
        fun(Left, Right) ->
            erl_syntax:copy_attrs(
                Left,
                erl_syntax:infix_expr(Left, Operator, Right)
            )
        end,
        First,
        Expressions
    ).

%% Returns the given node with all merl patterns replaced with temporary
%% variables, together with those variables.
%%
%% It takes the current set of bindings from the first argument, and updates
%% it with the temporary variables created during transformation.
% -dialyzer({nowarn_function, replace_merl_with_temporary_variables/2}).
-spec replace_merl_with_temporary_variables(Clause, Patterns) ->
    {Clause, PatternsWithoutMerl, Replacements}
when
    Clause :: merlin:ast(),
    Patterns :: [merlin:ast()],
    PatternsWithoutMerl :: [merlin:ast()],
    Replacements :: [{MerlPattern, TemporaryVariable}],
    MerlPattern :: merlin:ast(),
    TemporaryVariable :: merlin:ast().
replace_merl_with_temporary_variables(Clause0, Patterns) when is_list(Patterns) ->
    State = #{
        clause => Clause0,
        replacements => []
    },
    {PatternsWithoutMerl, #{
        clause := Clause1,
        replacements := Replacements
    }} = merlin:transform(
        Patterns,
        fun replacement_transformer/3,
        State
    ),
    {Clause1, PatternsWithoutMerl, Replacements}.

%% @private
replacement_transformer(
    enter,
    Form,
    #{clause := Clause0, replacements := Replacements} = State0
) ->
    case Form of
        ?Q("_@MerlPattern = _@Var") when
            is_merl_quote(MerlPattern) andalso is_variable(Var)
        ->
            %% There's already a variable for it, lets reuse it
            State1 = State0#{
                replacements := [{MerlPattern, Var} | Replacements]
            },
            {return, Var, State1};
        ?Q("_@MerlPattern") when is_merl_quote(MerlPattern) ->
            {Clause1, TemporaryVariable0} = merlin_bindings:new(Clause0),
            TemporaryVariable1 = erl_syntax:copy_attrs(
                MerlPattern,
                TemporaryVariable0
            ),
            State1 = State0#{
                clause := Clause1,
                replacements := [{MerlPattern, TemporaryVariable1} | Replacements]
            },
            {return, TemporaryVariable1, State1};
        _ ->
            continue
    end;
replacement_transformer(_, _, _) ->
    continue.

%% @doc Returns a node, or nodes, that {@link erlang:raise/3. raises} either
%% `function_clause' or `case_clause' as appropriately.
%%
%% It uses the `function_arguments' annotation to determine this. It also
%% ensures that the resulting error behaves exactly like the builtin one.
%% For function clause, it injects the function arguments into the first stack
%% frame, and for case clause it errors with the case argument.
raise_function_or_case_clause(CaseArgument0) ->
    case
        merlin_annotations:get(
            CaseArgument0,
            function_arguments,
            undefined
        )
    of
        undefined ->
            RaiseCaseClauseBody = ?Q([
                "erlang:error({case_clause, _@CaseArgument0})"
            ]),
            RaiseCaseClauseBody;
        FunctionArguments ->
            {_CaseArgument1, [
                CurrentFrame0,
                CurrentFrame1,
                Frames
            ]} = merlin_bindings:new(CaseArgument0, 3),
            RaiseFunctionClauseBody = ?Q([
                "{current_stacktrace, [_@CurrentFrame0 | _@Frames]} =",
                "    erlang:process_info(erlang:self(), current_stacktrace),",
                "_@CurrentFrame1 = erlang:setelement(",
                "    4, _@CurrentFrame0, [_@FunctionArguments]",
                "),",
                "erlang:raise(",
                "    error, function_clause, [_@CurrentFrame1 | _@Frames]",
                ")"
            ]),
            RaiseFunctionClauseBody
    end.

%% @equiv update_clause(Clause, Patterns, copy, copy)
update_clause(Clause, Patterns) ->
    update_clause(Clause, Patterns, copy).

%% @equiv update_clause(Clause, Patterns, Guard, copy)
update_clause(Clause, underscore, Body) ->
    update_clause(Clause, underscore, none, Body);
update_clause(Clause, Patterns, Guard) ->
    update_clause(Clause, Patterns, Guard, copy).

%% @doc Updates the given `Clause' with the given `Patterns', `Guard' and
%% `Body'.
%%
%% The `Patterns' may be `underscore', to indicate that the clause should match
%% any pattern(s). This also clears any guard. If you want a match all clause
%% with a guard, you need to use {@link erl_syntax:underscore/0} for the
%% patterns.
%%
%% The `Guard' may be `none', to indicate that there is no guard.
%% The `Body' may be a node or list of nodes.
%%
%% You may also use the atom `copy' for any of the arguments, to indicate that
%% the corresponding part of the `Clause' should be copied over.
-spec update_clause(Clause, Patterns, Guard, Body) -> merlin:erl_syntax_ast() when
    Clause :: merlin:ast(),
    Patterns :: copy | underscore | [merlin:ast()],
    Guard :: copy | none | merlin:ast(),
    Body :: copy | merlin:ast() | [merlin:ast()].
update_clause(Clause, underscore, _, Body) ->
    Patterns0 = erl_syntax:clause_patterns(Clause),
    Patterns1 = lists:duplicate(length(Patterns0), underscore(Clause)),
    update_clause(Clause, Patterns1, none, Body);
update_clause(Clause, Patterns0, Guard0, Body0) ->
    Patterns1 =
        case Patterns0 of
            copy -> erl_syntax:clause_patterns(Clause);
            _ -> maybe_wrap_in_list(Patterns0)
        end,
    Guard1 =
        case Guard0 of
            copy -> erl_syntax:clause_guard(Clause);
            _ -> Guard0
        end,
    Body1 =
        case Body0 of
            copy -> erl_syntax:clause_body(Clause);
            _ -> maybe_wrap_in_list(Body0)
        end,
    erl_syntax:copy_attrs(
        Clause,
        erl_syntax:clause(Patterns1, Guard1, Body1)
    ).

%% @doc Returns a {@link merl:underscore/0} with the attributes
%% {@link merl:copy_attrs/2. copied} from the given `Clause'.
underscore(Clause) ->
    Underscore = erl_syntax:underscore(),
    erl_syntax:copy_attrs(Clause, Underscore).

maybe_wrap_in_list(Forms) when is_list(Forms) ->
    Forms;
maybe_wrap_in_list(Form) ->
    [Form].

%% @doc Like {@link merlin:return/2}, while also applying the
%% {@link merl_transform:parse_transform/2. merl parse_transform}.
return(Result, Options) ->
    merlin_lib:then(merlin:return(Result), fun(Forms) ->
        merl_transform:parse_transform(Forms, Options)
    end).

%%%_* Tests ==================================================================
-ifdef(TEST).

-define(EXAMPLE_QUOTE_MARKER,
    ?STRINGIFY({'MERLIN QUOTE MARKER', "example.erl", 123, "erlang:max(1, 2)"})
).

is_merl_quote_test_() ->
    [
        ?_assert(is_merl_quote(?Q(?EXAMPLE_QUOTE_MARKER))),
        ?_assert(is_merl_quote(?Q("merl:quote(\"direct merl:quote call\")"))),
        ?_assertNot(is_merl_quote(?Q("some_other_form")))
    ].

has_quote_pattern_test_() ->
    [
        fun() ->
            Clauses = erl_syntax:function_clauses(Fun),
            ?assertEqual(Expected, has_quote_pattern(Clauses))
        end
     || {Expected, Fun} <- [
            {true,
                ?Q([
                    "func(" ?EXAMPLE_QUOTE_MARKER ") ->",
                    "   ok."
                ])},
            {true,
                ?Q([
                    "func(" ?EXAMPLE_QUOTE_MARKER ", other_argument) ->",
                    "   ok."
                ])},
            {true,
                ?Q([
                    "func(#state{form=" ?EXAMPLE_QUOTE_MARKER "}) ->",
                    "   ok."
                ])},
            {false,
                ?Q([
                    "func(#state{form=Form}) ->",
                    "   ok."
                ])}
        ]
    ].

%% Test helper, to make the transform_simple_test_/0 nice to read. Using a
%% macro makes ?Q/1 print better line numbers.
-define(_transformTest(Title, Original, Expected),
    {
        Title,
        fun() ->
            Options = [],
            Transformed = transform(?PREPEND_MODULE_FORMS(Original), Options),
            %% Strip away the module forms
            ?assertMatch([_, _, _, _], Transformed),
            [_, _, _, TransformedFunc] = Transformed,
            ?assertMerlEqual(Expected, TransformedFunc)
        end
    }
).

transform_simple_test_() ->
    Arg@0 = erl_syntax:variable(arg@0),
    Arg@1 = erl_syntax:variable(arg@1),
    Arg@2 = erl_syntax:variable(arg@2),
    ValueVar@0 = erl_syntax:variable(value_var@0),
    Var0 = erl_syntax:variable('var-0'),
    Var1 = erl_syntax:variable('var-1'),
    Var2 = erl_syntax:variable('var-2'),
    Var3 = erl_syntax:variable('var-3'),
    {
        foreach,
        %% Reset automatic variable counter used during tests
        fun merlin_bindings:reset_uniqueness_counter/0,
        [
            ?_transformTest(
                "Single merl pattern w/o guard",
                ?QUOTE(
                    func({'MERLIN QUOTE MARKER', "example.erl", 12, "_@Var"}) ->
                        {simple_merl_pattern, Var}
                ),
                ?Q([
                    "func(_@Arg@0) ->",
                    "    case _@Arg@0 of",
                    "        merl:quote(12, \"_@Var\") ->",
                    "            {simple_merl_pattern, Var}",
                    "    end."]
                )
            ),
            ?_transformTest(
                "Simple merl patterns",
                ?QUOTE(
                    func({'MERLIN QUOTE MARKER', "example.erl", 10, "_@Var"}) when
                        erl_syntax:type(Var) =:= variable
                    ->
                        {merl_guard, Var};
                    func({'MERLIN QUOTE MARKER', "example.erl", 14, "_@Pattern = _@Expr"}) when
                        is_tuple(Pattern)
                    ->
                        {erlang_guard, Expr};
                    func({'MERLIN QUOTE MARKER', "example.erl", 18, "_@Form"}) ->
                        {simple_merl_pattern, Form}
                ),
                ?Q([
                    "func(_@Arg@0) ->",
                    "    case _@Arg@0 of",
                    "        merl:quote(10, \"_@Var\") when",
                    "            erl_syntax:type(Var) =:= variable",
                    "        ->",
                    "            {merl_guard, Var};",
                    "        merl:quote(14, \"_@Pattern = _@Expr\") when",
                    "            is_tuple(Pattern)",
                    "        ->",
                    "            {erlang_guard, Expr};",
                    "        merl:quote(18, \"_@Form\") ->",
                    "            {simple_merl_pattern, Form}",
                    "    end."
                ])
            ),
            ?_transformTest(
                "Multiple arguments",
                ?QUOTE(
                    func(enter, {'MERLIN QUOTE MARKER', "example.erl", 10, "_@Var"}, State) when
                        erl_syntax:type(Var) =:= variable
                    ->
                        {merl_guard, Var};
                    func(enter, {'MERLIN QUOTE MARKER', "example.erl", 14, "_@Pattern = _@Expr"} = Form, State) ->
                        {assigned_whole_merl_pattern, Form};
                    func(enter, {'MERLIN QUOTE MARKER', "example.erl", 18, "_@Form"}, #{count := Count} = State) ->
                        {simple_merl_pattern, Form, State#{count := Count + 1}}
                ),
                ?Q([
                    "func(_@Arg@0, _@Arg@1, _@Arg@2) ->",
                    "    case merlin_quote_transform:switch(",
                    "        [_@Arg@0, _@Arg@1, _@Arg@2],",
                    "        [",
                    "            fun (enter, _@Var2, State) ->",
                    "                    case _@Var2 of",
                    "                        merl:quote(10, \"_@Var\") when",
                    "                            erl_syntax:type(Var) =:= variable",
                    "                        ->",
                    "                            {ok, {merl_guard, Var}};",
                    "                        _ ->",
                    "                            continue",
                    "                    end;",
                    "                (_, _, _) ->",
                    "                    continue",
                    "            end,",
                    %%           Note that `Form' is not replaced with a temporary variable
                    "            fun (enter, Form, State) ->",
                    "                    case Form of",
                    "                        merl:quote(14, \"_@Pattern = _@Expr\") ->",
                    "                            {ok, {assigned_whole_merl_pattern, Form}};",
                    "                        _ ->",
                    "                            continue",
                    "                    end;",
                    "                (_, _, _) ->",
                    "                    continue",
                    "            end,",
                    "            fun (enter, _@Var2, #{count := Count} = State) ->",
                    "                    case _@Var2 of",
                    "                        merl:quote(18, \"_@Form\") ->",
                    "                            {ok, {simple_merl_pattern, Form, State#{count := Count + 1}}};",
                    "                        _ ->",
                    "                            continue",
                    "                    end;",
                    "                (_, _, _) ->",
                    "                    continue",
                    "            end",
                    "        ]",
                    "    ) of",
                    "        {ok, _@ValueVar@0} ->",
                    "            _@ValueVar@0;",
                    "        _ ->",
                    "            {current_stacktrace, [_@Var0 | _@Var2]} =",
                    "                erlang:process_info(erlang:self(), current_stacktrace),",
                    "            _@Var1 = erlang:setelement(4, _@Var0, [_@Arg@0, _@Arg@1, _@Arg@2]),",
                    "            erlang:raise(error, function_clause, [_@Var1 | _@Var2])",
                    "    end."
                ])
            ),
            ?_transformTest(
                "Multiple merl patterns per clause",
                ?QUOTE(
                    func(
                        {'MERLIN QUOTE MARKER', "example.erl", 10, "_@First"},
                        {'MERLIN QUOTE MARKER', "example.erl", 11, "_@Second"}
                    ) ->
                        Left = erl_syntax:variable_name(First),
                        Right = erl_syntax:variable_name(Second),
                        Left =:= Right
                ),
                ?Q([
                    "func(_@Arg@0, _@Arg@1) ->",
                    "    case merlin_quote_transform:switch(",
                    "        [_@Arg@0, _@Arg@1],",
                    "        [",
                    "            fun (_@Var2, _@Var3) ->",
                    "                    case _@Var3 of",
                    "                        merl:quote(11, \"_@Second\") ->",
                    "                            case _@Var2 of",
                    "                                merl:quote(10, \"_@First\") ->",
                    "                                    {ok, begin",
                    "                                        Left = erl_syntax:variable_name(First),",
                    "                                        Right = erl_syntax:variable_name(Second),",
                    "                                        Left =:= Right",
                    "                                    end};",
                    "                                _ ->",
                    "                                    continue",
                    "                            end;",
                    "                        _ ->",
                    "                            continue",
                    "                    end",
                    %%                 Since the first fun head always matches there's no need for
                    %%                 (_, _) -> continue
                    "            end",
                    "        ]",
                    "    ) of",
                    "        {ok, _@ValueVar@0} ->",
                    "            _@ValueVar@0;",
                    "        _ ->",
                    "            {current_stacktrace, [_@Var0 | _@Var2]} =",
                    "                erlang:process_info(erlang:self(), current_stacktrace),",
                    "            _@Var1 = erlang:setelement(4, _@Var0, [_@Arg@0, _@Arg@1]),",
                    "            erlang:raise(error, function_clause, [_@Var1 | _@Var2])",
                    "    end."
                ])
            ),
            ?_transformTest(
                "Nested merl pattern",
                ?QUOTE(
                    func(#state{
                        form={'MERLIN QUOTE MARKER', "example.erl", 10, "_@Pattern = _@Expr"},
                        bindings=Bindings
                    }) ->
                        erl_eval:expr(Expr, Bindings)
                ),
                ?Q([
                    "func(_@Arg@0) ->",
                    "    case merlin_quote_transform:switch(",
                    "        [_@Arg@0],",
                    "        [",
                    "            fun (#state{form=_@Var2, bindings=Bindings}) ->",
                    "                    case _@Var2 of",
                    "                        merl:quote(10, \"_@Pattern = _@Expr\") ->",
                    "                            {ok, erl_eval:expr(Expr, Bindings)};",
                    "                        _ ->",
                    "                            continue",
                    "                    end;",
                    "                (_) ->",
                    "                    continue",
                    "            end",
                    "        ]",
                    "    ) of",
                    "        {ok, _@ValueVar@0} ->",
                    "            _@ValueVar@0;",
                    "        _ ->",
                    "            {current_stacktrace, [_@Var0 | _@Var2]} =",
                    "                erlang:process_info(erlang:self(), current_stacktrace),",
                    "            _@Var1 = erlang:setelement(4, _@Var0, [_@Arg@0]),",
                    "            erlang:raise(error, function_clause, [_@Var1 | _@Var2])",
                    "    end."
                ])
            ),
            ?_transformTest(
                "No merl pattern with extended guard",
                ?QUOTE(
                    func(enter, {'MERLIN QUOTE MARKER', "example.erl", 10, "_@Pattern = _@Expr"}, _) ->
                        match;
                    func(enter, Clause, _) when erl_syntax:type(Clause) =:= clause ->
                        clause
                ),
                ?Q([
                    "func(_@Arg@0, _@Arg@1, _@Arg@2) ->",
                    "    case merlin_quote_transform:switch(",
                    "        [_@Arg@0, _@Arg@1, _@Arg@2],",
                    "        [",
                    "            fun (enter, _@Var2, _) ->",
                    "                    case _@Var2 of",
                    "                        merl:quote(10, \"_@Pattern = _@Expr\") ->",
                    "                            {ok, match};",
                    "                        _ ->",
                    "                            continue",
                    "                    end;",
                    "                (_, _, _) ->",
                    "                    continue",
                    "            end,",
                    "            fun (enter, Clause, _) ->",
                    "                case",
                    "                    try",
                    "                        erl_syntax:type(Clause) =:= clause",
                    "                    catch",
                    "                        _:_ ->",
                    "                            false",
                    "                    end",
                    "                of",
                    "                    true ->",
                    "                        {ok, clause};",
                    "                    _ ->",
                    "                        continue",
                    "                end;",
                    "            (_, _, _) ->",
                    "                continue",
                    "            end",
                    "        ]",
                    "    ) of",
                    "        {ok, _@ValueVar@0} ->",
                    "            _@ValueVar@0;",
                    "        _ ->",
                    "            {current_stacktrace, [_@Var0 | _@Var2]} =",
                    "                erlang:process_info(erlang:self(), current_stacktrace),",
                    "            _@Var1 = erlang:setelement(4, _@Var0, [_@Arg@0, _@Arg@1, _@Arg@2]),",
                    "            erlang:raise(error, function_clause, [_@Var1 | _@Var2])",
                    "    end."
                ])
            )
        ]
    }.

-endif.
