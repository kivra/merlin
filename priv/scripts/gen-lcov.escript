#!/usr/bin/env escript

-record(function, {
    module :: module(),
    name :: atom(),
    arity :: arity(),
    start_line :: non_neg_integer(),
    calls :: pos_integer(),
    covered :: pos_integer(),
    not_covered :: pos_integer()
}).

-record(line, {
    line :: non_neg_integer(),
    calls :: pos_integer()
}).

-record(clause, {
    module :: module(),
    function :: atom(),
    arity :: arity(),
    position :: non_neg_integer(),
    calls :: pos_integer(),
    covered :: pos_integer(),
    not_covered :: pos_integer()
}).

-record(analysis, {
    module :: module(),
    source_file :: file:filename(),
    functions :: [#function{}],
    clauses :: [#clause{}],
    lines :: [#line{}],
    covered :: pos_integer(),
    not_covered :: pos_integer()
}).

main(_) ->
    cover:import("_build/test/cover/eunit.coverdata"),
    code:add_path("_build/test/lib/merlin/ebin"),
    LCOVPath = "_build/test/cover/lcov.info",
    {ok, File} = file:open(LCOVPath, [write]),
    lists:foreach(
        fun(Module) ->
            print(File, analyse(Module))
        end,
        cover:imported_modules()
    ),
    io:format("  coverage written to: ~s\n", [filename:absname(LCOVPath)]).


analyse(Module) ->
    Forms = merlin_internal:parse(Module),
    FunctionPositions = maps:from_list([
        {
            {
                erl_syntax:atom_value(erl_syntax:function_name(Function)),
                erl_syntax:function_arity(Function)
            },
            merlin_annotations:get(Function, line)
        }
     || Function <- Forms,
        erl_syntax:type(Function) =:= function
    ]),
    {result, RawFunctionCalls, _} = cover:analyse([Module], calls, function),
    FunctionCalls = maps:from_list([
        {{Name, Arity}, Calls}
     || {{_, Name, Arity}, Calls} <- RawFunctionCalls
    ]),
    {result, RawFunctionCoverage, _} = cover:analyse([Module], coverage, function),
    Functions = [
        #function{
            module = Module,
            name = Name,
            arity = Arity,
            start_line = maps:get({Name, Arity}, FunctionPositions),
            calls = maps:get({Name, Arity}, FunctionCalls),
            covered = Covered,
            not_covered = NotCovered
        }
     || {{_, Name, Arity}, {Covered, NotCovered}} <- RawFunctionCoverage,
        maps:is_key({Name, Arity}, FunctionPositions)
    ],
    {result, RawClauseCoverage, _} = cover:analyse([Module], coverage, clause),
    ClauseCoverage = maps:from_list([
        {{Name, Arity, Position}, #clause{
            module = Module,
            function = Name,
            arity = Arity,
            position = Position,
            covered = Covered,
            not_covered = NotCovered
        }}
     || {{_, Name, Arity, Position}, {Covered, NotCovered}} <- RawClauseCoverage
    ]),
    {result, RawClauseCalls, _} = cover:analyse([Module], calls, clause),
    Clauses = [
        (maps:get({Name, Arity, Position}, ClauseCoverage))#clause{
            calls = Calls
        }
     || {{_, Name, Arity, Position}, Calls} <- RawClauseCalls
    ],
    {result, [{Module, {TotalCovered, TotalNotCovered}}], _} = cover:analyse(
        [Module], coverage, module
    ),
    {result, RawLineCalls, _} = cover:analyse([Module], calls, line),
    Lines = [
        #line{
            line = Line + 1,
            calls = Calls
        }
     || {{_, Line}, Calls} <- RawLineCalls
    ],
    #analysis{
        module = Module,
        source_file = merlin_module:find_source(Module),
        functions = Functions,
        clauses = Clauses,
        lines = Lines,
        covered = TotalCovered,
        not_covered = TotalNotCovered
    }.

print(File, #analysis{} = Analysis) ->
    ok = file:write(File, [
        %% No test name.
        <<"TN:\n">>,
        [<<"SF:">>, Analysis#analysis.source_file, $\n],
        [
            io_lib:format("FN:~w,~w/~w\n", [StartLine, Name, Arity])
         || #function{start_line = StartLine, name = Name, arity = Arity} <-
                Analysis#analysis.functions
        ],
        io_lib:format("FNF:~w\n", [length(Analysis#analysis.functions)]),
        io_lib:format("FNH:~w\n", [count_covered(Analysis#analysis.functions)]),
        [
            io_lib:format("FNDA:~w,~w/~w\n", [Calls, Name, Arity])
         || #function{calls = Calls, name = Name, arity = Arity} <-
                Analysis#analysis.functions
        ],
        [
            io_lib:format("DA:~w,~w\n", [Line, Calls])
         || #line{line = Line, calls = Calls} <- Analysis#analysis.lines
        ],
        io_lib:format("LF:~w\n", [length(Analysis#analysis.lines)]),
        io_lib:format("LH:~w\n", [Analysis#analysis.covered]),
        <<"end_of_record">>
    ]).

count_covered([]) ->
    0;
count_covered([#function{} | _] = Functions) ->
    length(['_' || #function{covered = Covered} <- Functions, Covered > 0]);
count_covered([#line{} | _] = Lines) ->
    length(['_' || #line{calls = Calls} <- Lines, Calls > 0]).
