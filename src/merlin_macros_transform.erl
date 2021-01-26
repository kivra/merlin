-module(merlin_macros_transform).

% -behaviour(parse_transform).

-export([
    parse_transform/2
]).

-include_lib("syntax_tools/include/merl.hrl").
-include("log.hrl").

parse_transform(Forms, Options) when is_list(Forms) ->
    case proplists:get_bool(debug_info, Options) of
        false -> ok;
        true  ->
            %% Maybe do some sanity checks here, like reparse the file,
            %% find the macro definition and check the name etc
            ok
    end,
    put(module, merlin_lib:module(Forms)),
    put(file, merlin_lib:file(Forms)),
    {FinalForms, _FinalState} = merlin:transform(
        Forms, fun eval_procedural_macros/3, Options
    ),
    merlin:return(FinalForms).


eval_procedural_macros(enter, Form, _Options) ->
    case Form of
        ?Q([ "'@Name'(_@Args) when _@__@Guard -> _@_@Body." ]) ->
            put(bindings, erl_syntax_lib:variables(Form)),
            continue;
        _ -> continue
    end;
eval_procedural_macros(exit, Form, Options) ->
    case Form of
        ?Q([ "merlin_internal:'DEFINE PROCEDURAL MACRO'("
           , "    _@FileNode, _@LineNode,"
           ,"     _@ModuleNode, _@FunctionNode, _@ArityNode,"
           , "    _@MacroSource, fun() -> _@Body end"
           , ")"]) ->
                % Macro = merlin_lib:quote(FileNode, LineNode, MacroSource),
                eval(Body, Options);
        ?Q([ "'MERLIN INTERNAL DEFINE PROCEDURAL MACRO'() ->"
           , "    _@FileNode, _@LineNode, _@ModuleNode,"
           , "    _@MacroSource, _@Body."]) ->
            % Macro = merlin_lib:quote(FileNode, LineNode, MacroSource),
            eval(Body, Options);
        _ -> continue
    end;
eval_procedural_macros(_, _, _) -> continue.

eval(Body, Options) ->
    [Merl] = merl_transform:parse_transform([Body], Options),
    try
        erl_eval:expr(
            Merl,
            erl_eval:new_bindings(),
            {eval, fun function_handler/3}, %% Local function handler
            none, %% Remote function handler
            value
        )
    catch error:Reason:Stack ->
        StackTrace = ensure_location(Merl, Stack),
        Message = merlin_lib:erl_error_format(Reason, StackTrace),
        merlin_lib:format_error_marker(Message, StackTrace)
    end.

function_handler(abstract, Arguments, Bindings) ->
    {value, Arguments, Bindings};
function_handler(bindings, [], Bindings) ->
    {value, get(bindings), Bindings};
function_handler(Function, Arguments, _Bindings) ->
    StackTrace = [{
        get(module),
        Function,
        length(Arguments),
        location(hd(Arguments))
    }],
    erlang:raise(error, undef, StackTrace).

location(Node) ->
    [{file, get(file)}, {line, erl_syntax:get_pos(Node)}].

ensure_location(Node, [{Module, Function, Arity, []}|StackTrace]) ->
    [{Module, Function, Arity, location(Node)}|StackTrace];
ensure_location(_Node, StackTrace) ->
    StackTrace.