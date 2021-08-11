%%% @doc
%%% @private
%%% Private functions taken from merl.erl and tweaked to return an iolist
%%% rather then print to stdout.
%%% @end

-module(merlin_merl).

-export([
    format/1,
    show/1
]).


%% @doc Pretty-print a syntax tree or template to the standard output. This
%% is a utility function for development and debugging.

format(Ts) when is_list(Ts) ->
    unicode:characters_to_list(lists:map(fun format/1, Ts));
format(T) ->
    unicode:characters_to_list([
        erl_prettypr:format(merl:tree(T)),
        $\n
    ]).


%% @doc Print the structure of a syntax tree or template to the standard
%% output. This is a utility function for development and debugging.
show(Ts) when is_list(Ts) ->
    unicode:characters_to_list(lists:map(fun show/1, Ts));
show(T) ->
    unicode:characters_to_list([
        pp(merl:tree(T), 0),
        $\n
    ]).

pp(T, I) ->
    [lists:duplicate(I, $\s),
     limit(lists:flatten([atom_to_list(type(T)), ": ",
                          erl_prettypr:format(erl_syntax_lib:limit(T,3))]),
           79-I),
     $\n,
     pp_1(lists:filter(fun (X) -> X =/= [] end, subtrees(T)), I+2)
    ].

pp_1([G], I) ->
    pp_2(G, I);
pp_1([G | Gs], I) ->
    [pp_2(G, I), lists:duplicate(I, $\s), "+\n" | pp_1(Gs, I)];
pp_1([], _I) ->
    [].

pp_2(G, I) ->
    [pp(E, I) || E <- G].

%% limit string to N characters, stay on a single line and compact whitespace
limit([$\n | Cs], N) -> limit([$\s | Cs], N);
limit([$\r | Cs], N) -> limit([$\s | Cs], N);
limit([$\v | Cs], N) -> limit([$\s | Cs], N);
limit([$\t | Cs], N) -> limit([$\s | Cs], N);
limit([$\s, $\s | Cs], N) -> limit([$\s | Cs], N);
limit([C | Cs], N) when C < 32 -> limit(Cs, N);
limit([C | Cs], N) when N > 3 -> [C | limit(Cs, N-1)];
limit([_C1, _C2, _C3, _C4 | _Cs], 3) -> "...";
limit(Cs, 3) -> Cs;
limit([_C1, _C2, _C3 | _], 2) -> "..";
limit(Cs, 2) -> Cs;
limit([_C1, _C2 | _], 1) -> ".";
limit(Cs, 1) -> Cs;
limit(_, _) -> [].

%% wrappers around erl_syntax functions to provide more uniform shape of
%% generic subtrees (maybe this can be fixed in syntax_tools one day)

type(T) ->
    case erl_syntax:type(T) of
        nil  -> list;
        Type -> Type
    end.

subtrees(T) ->
    case erl_syntax:type(T) of
        tuple ->
            [erl_syntax:tuple_elements(T)];  %% don't treat {} as a leaf
        nil ->
            [[], []];  %% don't treat [] as a leaf, but as a list
        list ->
            case erl_syntax:list_suffix(T) of
                none ->
                    [erl_syntax:list_prefix(T), []];
                S ->
                    [erl_syntax:list_prefix(T), [S]]
            end;
        binary_field ->
            [[erl_syntax:binary_field_body(T)],
             erl_syntax:binary_field_types(T)];
        clause ->
            case erl_syntax:clause_guard(T) of
                none ->
                    [erl_syntax:clause_patterns(T), [],
                     erl_syntax:clause_body(T)];
                G ->
                    [erl_syntax:clause_patterns(T), [G],
                     erl_syntax:clause_body(T)]
            end;
        receive_expr ->
            case erl_syntax:receive_expr_timeout(T) of
                none ->
                    [erl_syntax:receive_expr_clauses(T), [], []];
                E ->
                    [erl_syntax:receive_expr_clauses(T), [E],
                     erl_syntax:receive_expr_action(T)]
            end;
        record_expr ->
            case erl_syntax:record_expr_argument(T) of
                none ->
                    [[], [erl_syntax:record_expr_type(T)],
                     erl_syntax:record_expr_fields(T)];
                V ->
                    [[V], [erl_syntax:record_expr_type(T)],
                     erl_syntax:record_expr_fields(T)]
            end;
        record_field ->
            case erl_syntax:record_field_value(T) of
                none ->
                    [[erl_syntax:record_field_name(T)], []];
                V ->
                    [[erl_syntax:record_field_name(T)], [V]]
            end;
        _ ->
            erl_syntax:subtrees(T)
    end.

%% End merl private functions