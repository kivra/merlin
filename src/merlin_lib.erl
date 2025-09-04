%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Helpers for working with {@link erl_syntax:syntaxTree()}.
%%%
%%% Similar to {@link erl_syntax_lib}, but with a different set of helpers,
%%% and a preference for returning maps over proplists.
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%_* Module declaration =====================================================
-module(merlin_lib).

%%%_* Exports ================================================================
%%%_ * API -------------------------------------------------------------------
-export([
    deep_find_by/2,
    find_by/2,
    flatten/1,
    is_erl_syntax/1,
    then/2,
    update_tree/2,
    value/1
]).

%%%_* Types ------------------------------------------------------------------

%%%_* Includes ===============================================================
-include("internal.hrl").
-include("assertions.hrl").

%%%_* Macros =================================================================

%%%_* Types ==================================================================

-type predicate(T) :: fun((T) -> boolean()).

-type predicate() :: predicate(merlin:ast()).

%%%_* Code ===================================================================
%%%_ * API -------------------------------------------------------------------

%% @doc Updates the given node using the given groups or subtrees of another
%% node.
%%
%% This is a generalisation of {@link erl_syntax:update_tree/2}.
-spec update_tree(merlin:ast(), [[merlin:ast()]] | merlin:ast()) -> merlin:ast().
update_tree(Node, Groups) when is_list(Groups) ->
    erl_syntax:update_tree(Node, Groups);
update_tree(Node, Tree) when is_tuple(Tree) ->
    ?assertNodeType(Node, ?assertIsNode(Tree)),
    erl_syntax:update_tree(Node, erl_syntax:subtrees(Tree)).

%% @doc Returns a flat list of nodes from the given
%% {@link erl_syntax:form_list/1. form list} or list of nodes.
-spec flatten(NodeOrNodes) -> [merlin:ast()] when
    NodeOrNodes :: merlin:ast() | [NodeOrNodes].
flatten(NodeOrNodes) ->
    Nodes0 = lists:flatten([NodeOrNodes]),
    Nodes1 = erl_syntax:form_list(Nodes0),
    Nodes2 = erl_syntax:flatten_form_list(Nodes1),
    Nodes3 = erl_syntax:form_list_elements(Nodes2),
    Nodes3.

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
                _ -> ?raise_error({badvalue, Node}, [Node], #{cause => unknown_type})
            end;
        false ->
            ?raise_error({badvalue, Node}, [Node], #{cause => not_literal})
    end.

%% @doc Calls the given function with the forms inside the given `Result',
%% while preserving any errors and/or warnings.
-spec then(Result, fun((Forms) -> Forms)) -> Result when
    Result :: merlin:parse_transform_return(Forms),
    Forms :: [merlin:ast()].
then({warning, Tree, Warnings}, Fun) when is_function(Fun, 1) ->
    {warning, Fun(Tree), Warnings};
then({error, Error, Warnings}, Fun) when is_function(Fun, 1) ->
    {error, Error, Warnings};
then(Tree, Fun) when is_function(Fun, 1) ->
    Fun(Tree).

%% @doc Return the first `Node' that satisfies the given function, or
%% `{error, notfound}' if no such form is found.
%%
%% The search is performed shallowly.
%%
%% @see deep_find_by/2
-spec find_by([merlin:ast()], predicate(Node)) -> {ok, Node} | {error, notfound} when
    Node :: merlin:ast().
find_by(Nodes, Fun) when is_function(Fun, 1) ->
    case lists:search(Fun, Nodes) of
        {value, Node} ->
            {ok, Node};
        false ->
            {error, notfound}
    end.

%% @doc Returns the first `Node' that satisfies the given function, or
%% `{error, notfound}' if no such `Node' is found.
%%
%% The search is performed recursively.
-spec deep_find_by(merlin:ast() | [merlin:ast()], predicate()) ->
    {ok, merlin:ast()} | {error, notfound}.
deep_find_by(Forms0, Predicate) when
    (is_list(Forms0) orelse is_tuple(Forms0)) andalso is_function(Predicate, 1)
->
    Forms1 = flatten(Forms0),
    try merlin:transform(Forms1, fun find_form_transformer/3, Predicate) of
        _ -> {error, notfound}
    catch
        %% Use the `fun' in the pattern to make it less likely to accidentally
        %% catch something else.
        error:{found, Predicate, Form} -> {ok, Form}
    end.

%% @doc Returns `true' if the given syntax node is a {@link erl_syntax} node,
%% `false' otherwise.
-dialyzer({nowarn_function, is_erl_syntax/1}).
-spec is_erl_syntax
    (merlin:erl_syntax_ast()) -> true;
    (merlin:erl_parse()) -> false.
is_erl_syntax(Node) when is_tuple(Node) ->
    Type = element(1, Node),
    Type =:= tree orelse Type =:= wrapper.

%%%_* Private ----------------------------------------------------------------
%% @private
find_form_transformer(Phase, Form, Fun) when ?oneof(Phase, enter, leaf) ->
    case Fun(Form) of
        true -> error({found, Fun, Form});
        false -> continue
    end;
find_form_transformer(_, _, _) ->
    continue.

%%%_* Tests ==================================================================
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-include_lib("syntax_tools/include/merl.hrl").

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

is_erl_syntax_test_() ->
    maps:to_list(#{
        "erl_parse node" => ?_assertNot(is_erl_syntax(?Q("1 + 2"))),
        "erl_syntax node" => ?_assert(is_erl_syntax(erl_syntax:variable("Foo")))
    }).

-endif.
