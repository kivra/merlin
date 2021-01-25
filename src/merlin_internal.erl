-module(merlin_internal).

-export([
    'DEFINE PROCEDURAL MACRO'/7
]).

-export([
    format_forms/1,
    format_stack/1,
    log_macro/4,
    pretty/1,
    write_log_file/0
]).

'DEFINE PROCEDURAL MACRO'(File, Line, Module, 'MERLIN INTERNAL DEFINE PROCEDURAL MACRO', 0, Macro, _BodyFun) ->
    Function = '',
    Arity = 0,
    erlang:raise(error, {missing_parse_transform, lists:concat([
        "To use merlin macros you must enable the merlin parse transform. ",
        "In macro expression ?", Macro
    ])}, [{Module, Function, Arity, [{file, File}, {line, Line}]}]);
'DEFINE PROCEDURAL MACRO'(File, Line, Module, Function, Arity, Macro, _BodyFun) ->
    erlang:raise(error, {missing_parse_transform, lists:concat([
        "To use merlin macros you must enable the merlin parse transform. ",
        "In macro expression ?", Macro
    ])}, [{Module, Function, Arity, [{file, File}, {line, Line}]}]).

%% @private
%% @doc This is a helper for the ?level(A, B, C) macros.
%% Unfortunately it can't be inlined because dialyzer complains about
%% "Guard test ... can never succeed". Which is true, but not relevant in the
%% context of a macro designed to be called in multiple different ways.
-spec log_macro(logger:level(), term(), term(), logger:metadata()) -> ok.
log_macro(Level, Format, Metadata, MacroMetadata) when
    (not is_function(Format)) andalso is_map(Metadata)
->
    logger:log(Level, Format, maps:merge(MacroMetadata, Metadata));
log_macro(Level, A, B, Metadata) ->
    logger:log(Level, A, B, Metadata).

write_log_file() ->
    %% Only flush if our logger is active
    case lists:member(debug_log, logger:get_handler_ids()) of
        true -> logger_std_h:filesync(debug_log);
        false -> ok
    end.

%% @doc Returns a {Format, Arguments} pair with the given `Prefix' and `Forms'.
%% This first tries to render the given 'Forms' as Erlang syntax using
%% {@link erl_pp}, then as normal Erlang forms, {@link merlin:revert/1.
%% reverting} as needed, and finally just using `"~tp"' with {@link
%% io_lib:format/2}.
-spec format_forms({string(), merlin:ast() | [merlin:ast()] | term()}) -> {string(), [iolist()]}.
format_forms({Prefix, Forms}) ->
    {"~s~n~s", [Prefix, [
        try
            pretty(Form)
        catch
            throw:invalid_form ->
                io_lib:format("~tp", [merlin:revert(Form)]);
            _:_ ->
                io_lib:format("~tp", [Form])
        end
    ||
        Form <- lists:flatten([Forms])
    ]]}.

%% @doc Renders the given AST using {@link erl_pp} or throws `invalid_form'.
-spec pretty(merlin:ast() | [merlin:ast()]) -> iolist() | no_return().
pretty(Nodes) when is_list(Nodes) ->
    lists:foreach(fun pretty/1, Nodes);
pretty(Node) ->
    Columns = case io:columns() of
        {ok, Value} -> Value;
        {error, enotsup} -> 120
    end,
    Options = [{linewidth, Columns}],
    Form = merlin:revert(Node),
    IOList = case erl_syntax:is_form(Form) of
        true ->
            erl_pp:form(Form, Options);
        false ->
            erl_pp:expr(Form, Options)
    end,
    case is_invalid(IOList) of
        true -> throw(invalid_form);
        false -> IOList
    end.

is_invalid(IOList) ->
    foldl_iolist(fun match_prefix/2, "INVALID-FORM", IOList).

match_prefix(_, []) -> true;
match_prefix(Char, [Char|RestToMatch]) -> RestToMatch;
match_prefix(_, true) -> true;
match_prefix(_, _) -> false.

foldl_iolist(_, Result, []) -> Result;
foldl_iolist(_, Result, <<>>) -> Result;
foldl_iolist(Fun, AccIn, [Nested|Rest]) when is_list(Nested) orelse is_binary(Nested) ->
    AccOut = foldl_iolist(Fun, AccIn, Nested),
    foldl_iolist(Fun, AccOut, Rest);
foldl_iolist(Fun, AccIn, Binary) when is_binary(Binary) ->
    foldl_binary(Fun, AccIn, Binary);
foldl_iolist(Fun, AccIn, [Char|Rest]) when is_integer(Char) ->
    AccOut = Fun(Char, AccIn),
    foldl_iolist(Fun, AccOut, Rest).

foldl_binary(_, Result, <<>>) -> Result;
foldl_binary(Fun, AccIn, <<Char/utf8>>) ->
    Fun(Char, AccIn);
foldl_binary(Fun, AccIn, <<Char/utf8, Rest/binary>>) ->
    AccOut = Fun(Char, AccIn),
    foldl_binary(Fun, AccOut, Rest).

%% @doc Returns the given stack trace into something nice, with colors and all.
%% This makes it more amedable for reading, and also openable in your
%% favorite editor.
-spec format_stack([Frame]) -> iolist()
when
    Frame :: {module(), FunctionName, ArityOrArguments, Location},
    FunctionName :: atom(),
    ArityOrArguments :: arity() | [term()],
    Location :: [{file, string()} | {line, pos_integer()}].
format_stack(StackTrace) ->
    %% Use dimmed to make it usable on both light and dark backgrounds.
    Dimmed = "\e[2;39m",
    Normal = "\e[0m",
    [
        if is_integer(ArityOrArguments) ->
            io_lib:format("  ~s:~s/~p ~sin~s ~s:~p~n", [
                    Module, Function, ArityOrArguments,
                    Dimmed, Normal,
                    proplists:get_value(file, Location, none),
                    proplists:get_value(line, Location, none)
                ]);
        true ->
            io_lib:format("  ~s:~s/~p ~swith~s ~tw ~sin~s ~s:~p~n", [
                    Module, Function, length(ArityOrArguments),
                    Dimmed, Normal, ArityOrArguments,
                    Dimmed, Normal,
                    proplists:get_value(file, Location, none),
                    proplists:get_value(line, Location, none)
                ])
        end
    ||
        {Module, Function, ArityOrArguments, Location} <- StackTrace
    ].
