%%% @doc Example uses of merlin
%%% @end
-module(merlin_example).

-export([
    count_atoms_erl_syntax/0,
    count_atoms_record/0,
    parse_merlin/0,
    parse_module/2,
    print/0,
    form_list/0,
    flat/0,
    enable_trace/0,
    disable_trace/0,
    dup/1,
    f/0,
    match/2,
    trace/0,
    compile/0,
    tree/0,
    parse_string/1
]).

parse_string(Source) ->
    Src = case lists:last(Source) of
        $. -> Source;
        _ -> Source ++ "."
    end,
    {ok, Tokens, _} = erl_scan:string(Src, {1,1}),
    {ok, AST} = erl_parse:parse_exprs(Tokens),
    AST.

tree() ->
    [{clause,26,
                [{atom,26,enter},
                {tuple,26,
                        [{atom,26,'MERLIN QUOTE MARKER'},
                        {string,26,
                                "/Users/maxno/Documents/Kivra/merlin/src/ex.erl"},
                        {integer,26,26},
                        {string,26,"logger:log(_@Level, _@Message)"}]},
                {var,26,'State'}],
                [],
                [{atom,26,continue}]},
        {clause,27,
                [{atom,27,enter},
                {tuple,27,
                        [{atom,27,'MERLIN QUOTE MARKER'},
                        {string,27,
                                "/Users/maxno/Documents/Kivra/merlin/src/ex.erl"},
                        {integer,27,27},
                        {string,27,"other:call(_@Message)"}]},
                {var,27,'State'}],
                [],
                [{atom,27,continue}]},
        {clause,28,
                [{var,28,'_'},{var,28,'_'},{var,28,'_'}],
                [],
                [{atom,28,continue}]}].

match(Pattern, Target) ->
    Tree = merl:quote(Target),
    Template = merl:template(merl:quote(Pattern)),
    merl:match(Template, Tree).

trace() ->
    erlang:system_flag(backtrace_depth, 100),
    dbg:tracer(),
    dbg:p(all, c),
    lists:foreach(fun(Function) ->
        dbg:tpl(compile, Function, cx)
    end, [
        comp_ret_ok,
        comp_ret_err,
        report_errors,
        report_warnings,
        list_errors,
        messages_per_file
    ]),
    dbg:tpl(rebar_compiler_erl, cx).

compile() ->
    compile:file("src/ex.erl", [
        debug_info,
        report_errors,
        report_warnings,
        return_errors,
        return_warnings,
        verbose,
        {i,"/Users/maxno/Documents/Kivra/merlin/_build/default/lib/merlin"},
        {i,"/Users/maxno/Documents/Kivra/merlin/_build/default/lib/merlin/include"},
        {i,"/Users/maxno/Documents/Kivra/merlin/_build/default/lib/merlin/src"},
        {outdir,"/Users/maxno/Documents/Kivra/merlin/_build/default/lib/merlin/ebin"}
    ]).

dup(Module) ->
    Forms = parse_module(Module, [epp]),
    merlin:transform(Forms, fun duper/3, '_').

duper(enter, Node, _) ->
    case erl_syntax:type(Node) of
        application ->
            [Node, Node];
        _ -> continue
    end;
duper(_, _, _) -> continue.

f() -> fun() ->
    Foo = 123,
    Bar = 456,
    {Foo, Bar}
end.

% -include("merlin_example.hrl").

-define(INDENT, "  ").

form_list() ->
    Var = merl:quote("Foo = bar"),
    erl_syntax:form_list(
        [merl:quote("map"), merl:quote("123")] ++
        lists:duplicate(3, Var)
    ).

flat() -> erl_syntax:flatten_form_list(form_list()).

-define(traced_modules, [merlin, merlin_macros_transform, erl_syntax]).

enable_trace() ->
    MatchSpec = [{
        '_',
        [],
        % [{return_trace}]
        [{exception_trace}]
    }],
    PatternFlags = [local],
    Pid = spawn(fun tracer/0),
    io:format("~tp~n", [Pid]),
    erlang:trace(all, true, [
        call,
        return_to,
        {tracer, Pid}
    ]),
    lists:foreach(fun(Module) ->
        erlang:trace_pattern({Module, '_', '_'}, MatchSpec, PatternFlags)
    end, ?traced_modules),
    ok.

disable_trace() ->
    erlang:trace(existing, false, [all]).

tracer() ->
    Indent = case get(indent) of
        undefined -> "";
        I -> I
    end,
    receive
        {trace, _Pid, _Type, {erl_syntax, _, _}} ->
            ok;
        {trace, _Pid, _Type, {erl_syntax, _, _}, _} ->
            ok;
        {trace, _Pid, call, {Module, Function, Arguments}} ->
            "[" ++ Args = lists:droplast(lists:flatten(io_lib:format("~tW", [Arguments, 10]))),
            io:format("~scall ~tp:~tp(~s)~n", [Indent, Module, Function, Args]),
            put(indent, Indent ++ "  ");
        {trace, _Pid, return_to, {Module, Function, Arity}} ->
            io:format("~sreturn to ~tp:~tp/~tp~n", [Indent, Module, Function, Arity]);
        {trace, _Pid, return_from, {Module, Function, Arity}, ReturnValue} ->
            put(indent, Indent -- "  "),
            io:format("~sreturn from ~tp:~tp/~tp -> ~tW~n", [Indent, Module, Function, Arity, ReturnValue, 10]);
        {trace, _Pid, exception_from, {Module, Function, Arity}, {Class, Value}} ->
            put(indent, Indent -- "  "),
            io:format("~sexception from ~tp:~tp/~tp -> ~tp ~tW~n", [Indent, Module, Function, Arity, Class, Value, 10]);
        Message ->
            io:format("Unknown message~tw~n~n", [Message])
    end,
    tracer().

print() ->
    Forms = parse_merlin(),
    merlin:transform(Forms, fun printer/3, #{
        indent => 0
    }).

printer(enter, Tree, #{ indent := Indentation }) ->
    Type = erl_syntax:type(Tree),
    io:format("~*..*s~p~n", [Indentation, ?INDENT, "", Type]),
    {Tree, #{
        indent => Indentation+1
    }};
printer(node, Node, #{ indent := Indentation }) ->
    Type = erl_syntax:type(Node),
    Value = case erl_syntax:revert(Node) of
        {_, _, Val} -> Val;
        {nil, _} -> nil;
        Other -> Other
    end,
    io:format("~*..*s~p ~p~n", [Indentation, ?INDENT, "", Type, Value]),
    {Node, #{ indent => Indentation }};
printer(exit, Tree, #{ indent := Indentation }) ->
    Type = erl_syntax:type(Tree),
    io:format("~*..*s~p~n", [Indentation + length("end"), ?INDENT, "end", Type]),
    {Tree, #{
        indent => Indentation-1
    }}.

parse_merlin() ->
    Src = filename:dirname(?FILE),
    Include = filename:join([Src, "..", "include"]),
    MerlinErl = filename:join(Src, "merlin.erl"),
    {ok, Forms} = epp:parse_file(MerlinErl, [{includes, [Include]}]),
    Forms.

parse_module(Module, Options) ->
    File = code:which(Module),
    {ok, {Module, [{compile_info, CompileInfo}]}} = beam_lib:chunks(File, [compile_info]),
    #{
        options := CompileOptions,
        source := SourceFile
    } = maps:from_list(CompileInfo),
    case proplists:get_bool(epp, Options) of
        true ->
            Includes = proplists:get_all_values(i, CompileOptions),
            {ok, Forms} = epp:parse_file(SourceFile, [{includes, Includes}]),
            Forms;
        false ->
            {ok, Forms} = epp_dodger:parse_file(SourceFile),
            Forms
    end.

count_atoms_erl_syntax() ->
    Forms = parse_merlin(),
    State = undefined,
    {_, Atoms} = merlin:transform(Forms, fun gather_atoms_by_erl_syntax/3, State),
    Atoms.

% -define(target, expand_callback_return).
-define(target, flatten_forms).

gather_atoms_by_erl_syntax(enter, Form, _State) ->
    case erl_syntax:type(Form) of
        function ->
            NameNode = erl_syntax:function_name(Form),
            case erl_syntax:atom_value(NameNode) of
                ?target ->
                    {continue, Form, #{}};
                _ -> return
            end;
        _ -> continue
    end;
gather_atoms_by_erl_syntax(node, Form, Atoms) when is_map(Atoms) ->
    case erl_syntax:type(Form) of
        atom ->
            Name = erl_syntax:atom_value(Form),
            Count = maps:get(Name, Atoms, 0),
            {Form, Atoms#{ Name => Count + 1 }};
        _ -> continue
    end;
gather_atoms_by_erl_syntax(_, _, _) -> continue.

-record(function, {
    line :: pos_integer(),
    name :: atom(),
    arity :: pos_integer(),
    clauses :: [tuple()]
}).

-record(atom, {
    line :: pos_integer(),
    name :: atom()
}).

count_atoms_record() ->
    Forms = parse_merlin(),
    State = undefined,
    {_, Atoms} = merlin:transform(
        Forms,
        fun(Phase, Form, CurrentState) ->
            gather_atoms_by_record(Phase, merlin:revert(Form), CurrentState)
        end,
        State
    ),
    Atoms.

gather_atoms_by_record(enter, #function{name=?target} = FunctionTree, _State) ->
    {continue, FunctionTree, #{}};
gather_atoms_by_record(enter, #function{}, _State) ->
    return;
gather_atoms_by_record(node, #atom{name=Name} = AtomNode, Atoms) when is_map(Atoms) ->
    Count = maps:get(Name, Atoms, 0),
    {AtomNode, Atoms#{
        Name => Count + 1
    }};
gather_atoms_by_record(_, _, _) -> continue.

-ifdef(OLD).

% -include_lib("syntax_tools/include/merl.hrl").
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
    end,
    Forms
    .

-type transformer(Extra) :: merlin:transformer(Extra).

%%% @doc Annotates function definitions with the bindings using
%%% `erl_syntax_lib:with_bindings/2' before calling the inner transformer.
%%%
%%% This allows the inner transformer to safely generate new bindings, or
%%% otherwise act on the current set of env, free and bound bindings.
%%%
%%% @see erl_syntax_lib:annotate_bindings/2
-spec with_bindings(transformer(Extra)) -> transformer(Extra).
with_bindings(Transformer) when is_function(Transformer, 3) ->
    fun (enter, Form, Extra) ->
            case erl_syntax:type(Form) of
                function ->
                    Env = merlin_lib:get_annotation(Form, env, ordsets:new()),
                    AnnotatedTree = erl_syntax_lib:annotate_bindings(Form, Env),
                    Transformer(enter, AnnotatedTree, Extra);
                _ ->
                    Transformer(enter, Form, Extra)
            end;
        (Phase, Form, Extra) ->
            Transformer(Phase, Form, Extra)
    end.

-spec using_abstract_form(transformer(Extra)) -> transformer(Extra).
using_abstract_form(Transformer) when is_function(Transformer, 4) ->
    %% TODO, use erl_syntax:add_ann to keep annontations. May still break nested annotate_applications.
    fun(Phase, Form, Extra) ->
        Node = erl_syntax:revert(Form),
        Transformer(Phase, Node, Extra)
    end.

-endif.