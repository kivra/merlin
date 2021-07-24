-module(merlin_quote_transform).

% -behaviour(parse_transform).

-include_lib("syntax_tools/include/merl.hrl").
-include("log.hrl").

-export([parse_transform/2]).

-export([zip_/1]).

parse_transform(Forms, Options) ->
    AnnotatedForms = merlin:annotate(Forms, [file]),
    {FinalForms, _FinalState} = merlin:transform(
        AnnotatedForms, fun quote/3, #{
            options => Options,
            module => merlin_lib:module(Forms)
            % file => merlin_lib:file(Forms)
        }
    ),
    return(FinalForms, Options).

quote(enter, Form, #{ module := Module}) ->
    case Form of
        ?Q([ "'@Name'(_@Args) when _@__@Guard -> _@_@Clauses." ]) ->
            case has_quote_pattern(Clauses) andalso check_clauses(Clauses)  of
                false ->
                    continue;
                [] ->
                    ?info(
                        "Detected quote pattern in ~s:~s/~p",
                        [
                            Module,
                            merlin_lib:value(Name),
                            erl_syntax:function_arity(Form)
                        ]
                    ),
                    First = hd(Clauses),
                    NodeVar = erl_syntax:variable('__NODE__'),
                    Template = quote_pattern_template(First),
                    BlankClause = blank_clause(Clauses),
                    Groups = group_by_pattern(Template, Clauses, [[]]),
                    ?debug("Groups ~n~tp", [Groups]),
                    GroupsAsFunctions = groups_into_functions(NodeVar, BlankClause, Groups),
                    ?show("Functions", GroupsAsFunctions),
                    NewClauses = lists:flatmap(
                        fun erl_syntax:function_clauses/1, GroupsAsFunctions
                    ),
                    ?Q([ "'@Name'(_@_) ->"
                       , "    _@_NewClauses."]);
                Errors ->
                    {exceptions, Errors, Form, '_'}
            end;
        ?Q("{'MERLIN QUOTE MARKER', _@FileNode, _@LineNode, _@BodySource}") ->
            %% -define(Q(Text), merl:quote(?LINE, Text)).
            ?Q("merl:quote(_@LineNode, _@BodySource)");
        _ -> continue
    end;
quote(_, _, _) -> continue.

has_quote_pattern(Clauses) ->
    lists:any(fun is_merl_quote/1, [
        Pattern
    ||
        Clause <- Clauses,
        Pattern <- erl_syntax:clause_patterns(Clause)
    ]).

is_merl_quote(Pattern) ->
    case Pattern of
        ?Q("{'MERLIN QUOTE MARKER', _@@_}") -> true;
        _ -> false
    end.

quote_pattern_template(Clause) ->
    merl:template([
        case is_merl_quote(Pattern) of
            true -> ?Q("_@_");
            false -> Pattern
        end
    ||
        Pattern <- erl_syntax:clause_patterns(Clause)
    ]).

blank_clause(Clauses) ->
    case lists:search(fun all_patterns_blank/1, Clauses) of
        false -> [];
        {value, Clause} -> [make_clause(Clause, erl_syntax:underscore())]
    end.

all_patterns_blank(Clause) ->
    lists:all(
        fun(Pattern) ->
            erl_syntax:type(Pattern) == underscore
        end,
        erl_syntax:clause_patterns(Clause)
    ).

group_by_pattern(_Template, [], [Group|Groups]) ->
    lists:reverse([lists:reverse(Group)|Groups]);
group_by_pattern(Template, [Clause|Clauses], [Group|Groups]) ->
    case merl:match(Template, erl_syntax:clause_patterns(Clause)) of
        {ok, _} ->
            group_by_pattern(Template, Clauses, [[Clause|Group]|Groups]);
        _ ->
            NewTemplate = quote_pattern_template(Clause),
            group_by_pattern(
                NewTemplate,
                Clauses,
                [[Clause], lists:reverse(Group)|Groups]
            )
    end.

groups_into_functions(_NodeVar, _BlankClause, []) -> [];
groups_into_functions(NodeVar, BlankClause, [Clauses|Rest]) ->
    Function = case has_quote_pattern(Clauses) of
        true ->
            fold_function_into_case(NodeVar, BlankClause, Clauses);
        false ->
            ?Q([ "'this name is ignored'(_@_) ->"
               , "    _@_Clauses."])
    end,
    [Function|groups_into_functions(NodeVar, BlankClause, Rest)].

fold_function_into_case(NodeVar, BlankClause, [First|_] = Clauses) ->
    PartitionedByMerlQuote = [
        lists:partition(fun is_merl_quote/1, Patterns)
    ||
        Patterns <- zip(Clauses)
    ],
    Head = [
        case Partition of
            {[Pattern|_], _} -> erl_syntax:copy_pos(Pattern, NodeVar);
            {[], [Pattern|_]} -> Pattern
        end
    ||
        Partition <- PartitionedByMerlQuote
    ],
    CaseClauses = [
        case has_quote_pattern([Clause]) of
            true ->
                {value, Pattern} = lists:search(
                    fun is_merl_quote/1,
                    erl_syntax:clause_patterns(Clause)),
                make_clause(Clause, Pattern);
            false ->
                make_clause(Clause, erl_syntax:underscore())
        end
    ||
        Clause <- Clauses
    ] ++ BlankClause,
    NodeVar1 = erl_syntax:copy_pos(First, NodeVar),
    ?Q([ "'this name is ignored'(_@Head) ->"
        , "    case _@NodeVar1 of"
        , "        _@_ ->"
        , "            _@_CaseClauses"
        , "    end."]).

zip(Clauses) ->
    ListOfPatterns = lists:map(fun erl_syntax:clause_patterns/1, Clauses),
    zip_(ListOfPatterns).

zip_([Patterns]) ->
    [
        [Pattern]
    ||
        Pattern <- Patterns
    ];
zip_([A, B]) ->
    lists:zipwith(
        fun(X, Y) ->
            [X, Y]
        end,
        A, B);
zip_([A, B, C]) ->
    lists:zipwith3(
        fun(X, Y, Z) ->
            [X, Y, Z]
        end,
        A, B, C);
zip_(ListOfPatterns) ->
    {A, B} = split(ListOfPatterns, 2),
    lists:zipwith(
        fun(Xs, Ys) ->
            Xs ++ Ys
        end,
        zip_(A), zip_(B)).

split(ListOfPatterns, N) ->
    lists:split(ceil(length(ListOfPatterns)/N), ListOfPatterns).

make_clause(Clause, Pattern) ->
    erl_syntax:copy_pos(
        Clause,
        erl_syntax:clause(
            [Pattern],
            erl_syntax:clause_guard(Clause),
            erl_syntax:clause_body(Clause)
        )
    ).

check_clauses(Clauses) ->
    lists:flatten(check_only_one_quote_pattern(Clauses)).

check_only_one_quote_pattern(Clauses) ->
    lists:filtermap(
        fun(Clause) ->
            QuotePatterns = [
                Pattern
            ||
                Pattern <- erl_syntax:clause_patterns(Clause),
                is_merl_quote(Pattern)
            ],
            case QuotePatterns of
                []  -> false; %% No quote pattern, fine for this test
                [_] -> false;
                [_|Patterns] ->
                    {true, [
                        merlin_lib:into_error_marker(
                            "only one quote pattern allowed",
                            Pattern
                        )
                    ||
                        Pattern <- Patterns
                    ]}
            end
        end,
        Clauses
    ).

return(Result, Options) ->
    return(fun merl_transform:parse_transform/2, Result, Options).

return(_Fun, {error, _, _} = Result, _Options) ->
    Result;
return(Fun, {warnings, Forms, Warnings}, Options) ->
    {warnings, Fun(Forms, Options), Warnings};
return(Fun, Forms, Options) ->
    Fun(Forms, Options).