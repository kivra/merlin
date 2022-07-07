-module(merlin_internal).

-export([
    'DEFINE PROCEDURAL MACRO'/7
]).

-export([
    export_all/1,
    eunit/1,
    format_forms/1,
    format_merl_guard/2,
    format_stack/1,
    format_using_erl_error/2,
    fun_to_mfa/1,
    log_macro/4,
    pretty/1,
    print_stacktrace/1,
    quote/3,
    split_by/2,
    write_log_file/0
]).

-ifdef(MERLIN_INTERNAL_EXPORT_ALL).
-compile([export_all, nowarn_export_all]).
-endif.

'DEFINE PROCEDURAL MACRO'(
    File,
    Line,
    Module,
    'MERLIN INTERNAL DEFINE PROCEDURAL MACRO',
    0,
    Macro,
    _BodyFun
) ->
    Function = '',
    Arity = 0,
    erlang:raise(
        error,
        {missing_parse_transform,
            lists:concat([
                "To use merlin macros you must enable the merlin parse transform. ",
                "In macro expression ?",
                Macro
            ])},
        [{Module, Function, Arity, [{file, File}, {line, Line}]}]
    );
'DEFINE PROCEDURAL MACRO'(File, Line, Module, Function, Arity, Macro, _BodyFun) ->
    erlang:raise(
        error,
        {missing_parse_transform,
            lists:concat([
                "To use merlin macros you must enable the merlin parse transform. ",
                "In macro expression ?",
                Macro
            ])},
        [{Module, Function, Arity, [{file, File}, {line, Line}]}]
    ).

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
-spec format_forms({string(), merlin:ast() | [merlin:ast()] | term()}) ->
    {string(), [iolist()]}.
format_forms({Prefix, Forms}) when is_list(Prefix) ->
    {"~s~n~s", [
        Prefix,
        lists:join($\n, [
            try
                pretty(Form)
            catch
                throw:invalid_form ->
                    io_lib:format("~tp", [merlin:revert(Form)]);
                _:_ ->
                    io_lib:format("~tp", [Form])
            end
         || Form <- lists:flatten([Forms])
        ])
    ]};
format_forms(Forms) ->
    format_forms({"", Forms}).

%% @doc Returns the given merl guard, at the given line, formatted using
%% {@link merlin_merl:format/1}
format_merl_guard(Line, GuardSource) ->
    ExpandedMerlMacros = re:replace(
        GuardSource,
        %% Matches ?Q(...) calls
        "\\? *Q *\\( *(.+?) *\\)",
        %% and expands them like merl does
        "merl:quote(\\1)",
        [global, {return, list}]
    ),
    %% To make merl parse the pattern we need to make it a valid clause first
    Clause = merl:quote(Line, ExpandedMerlMacros ++ " -> ok"),
    %% We format the whole clause, revert merl:quote to their macro form,
    %% strip that extra body we added and finally compress it into one line.
    FormattedClause0 = merlin_merl:format(Clause),
    FormattedClause1 = string:replace(FormattedClause0, "merl:quote", "?Q", all),
    FormattedClause2 = re:replace(
        FormattedClause1,
        " *->\\s+ok\\s+$",
        "",
        [multiline]
    ),
    re:replace(FormattedClause2, "\\s+", " ", [multiline]).

%% @doc Returns the given stack trace into something nice, with colors and all.
%% This makes it more amenable for reading, and also openable in your
%% favorite editor.
-spec format_stack([Frame]) -> iolist() when
    Frame :: {module(), FunctionName, ArityOrArguments, Location},
    FunctionName :: atom(),
    ArityOrArguments :: arity() | [term()],
    Location :: [{file, string()} | {line, pos_integer()}].
format_stack({current_stacktrace, StackTrace}) ->
    format_stack(StackTrace);
format_stack(StackTrace) ->
    %% Use dimmed to make it usable on both light and dark backgrounds.
    Dimmed = "\e[2;39m",
    Normal = "\e[0m",
    [
        if
            is_integer(ArityOrArguments) ->
                io_lib:format("  ~s:~s/~p ~sin~s ~s:~p~n", [
                    Module,
                    Function,
                    ArityOrArguments,
                    Dimmed,
                    Normal,
                    proplists:get_value(file, Location, none),
                    proplists:get_value(line, Location, none)
                ]);
            true ->
                io_lib:format("  ~s:~s/~p ~swith~s ~tw ~sin~s ~s:~p~n", [
                    Module,
                    Function,
                    length(ArityOrArguments),
                    Dimmed,
                    Normal,
                    ArityOrArguments,
                    Dimmed,
                    Normal,
                    proplists:get_value(file, Location, none),
                    proplists:get_value(line, Location, none)
                ])
        end
     || {Module, Function, ArityOrArguments, Location} <- StackTrace
    ].

%% @doc Formats the given exception using {@link erl_error}.
%% It is guaranteed to keep it all on a single line.
-if(?OTP_RELEASE >= 24).
format_using_erl_error(Reason, StackTrace) ->
    Class = error,
    %% Ignore all frames to keep the message on one line
    StackFilter = fun(_M, _F, _A) -> true end,
    Formatter = fun(Term, _Indent) -> io_lib:format("~tp", [Term]) end,
    Options = #{
        stack_trim_fun => StackFilter,
        format_fun => Formatter
    },
    erl_error:format_exception(Class, Reason, StackTrace, Options).
-else.
format_using_erl_error(Reason, StackTrace) ->
    Indent = 1,
    Class = error,
    %% Ignore all frames to keep the message on one line
    StackFilter = fun(_M, _F, _A) -> true end,
    Formatter = fun(Term, _Indent) -> io_lib:format("~tp", [Term]) end,
    Encoding = utf8,
    erl_error:format_exception(
        Indent,
        Class,
        Reason,
        StackTrace,
        StackFilter,
        Formatter,
        Encoding
    ).
-endif.

%% @doc Renders the given AST using {@link erl_pp} or throws `invalid_form'.
-spec pretty(merlin:ast() | [merlin:ast()]) -> iolist() | no_return().
pretty(Nodes) when is_list(Nodes) ->
    lists:map(fun pretty/1, Nodes);
pretty(Node) ->
    Columns =
        case io:columns() of
            {ok, Value} -> Value;
            {error, enotsup} -> 120
        end,
    Options = [{linewidth, Columns}],
    Form = merlin:revert(Node),
    IOList =
        case erl_syntax:is_form(Form) of
            true ->
                erl_pp:form(Form, Options);
            false ->
                erl_pp:expr(Form, Options)
        end,
    case is_invalid(IOList) of
        true -> throw(invalid_form);
        false -> IOList
    end.

print_stacktrace({current_stacktrace, StackTrace}) ->
    io:format("~s~n", [format_stack(StackTrace)]);
print_stacktrace(Forms) ->
    {Format, Args} = format_forms(Forms),
    io:format(Format, Args).

is_invalid(IOList) ->
    foldl_iolist(fun match_prefix/2, "INVALID-FORM", IOList).

match_prefix(_, []) -> true;
match_prefix(Char, [Char | RestToMatch]) -> RestToMatch;
match_prefix(_, true) -> true;
match_prefix(_, _) -> false.

foldl_iolist(_, Result, []) ->
    Result;
foldl_iolist(_, Result, <<>>) ->
    Result;
foldl_iolist(Fun, AccIn, [Nested | Rest]) when
    is_list(Nested) orelse is_binary(Nested)
->
    AccOut = foldl_iolist(Fun, AccIn, Nested),
    foldl_iolist(Fun, AccOut, Rest);
foldl_iolist(Fun, AccIn, Binary) when is_binary(Binary) ->
    foldl_binary(Fun, AccIn, Binary);
foldl_iolist(Fun, AccIn, [Char | Rest]) when is_integer(Char) ->
    AccOut = Fun(Char, AccIn),
    foldl_iolist(Fun, AccOut, Rest).

foldl_binary(_, Result, <<>>) ->
    Result;
foldl_binary(Fun, AccIn, <<Char/utf8>>) ->
    Fun(Char, AccIn);
foldl_binary(Fun, AccIn, <<Char/utf8, Rest/binary>>) ->
    AccOut = Fun(Char, AccIn),
    foldl_binary(Fun, AccOut, Rest).

%% @doc Splits `List' using `Fun' at the element for which it returns `true'.
%% That element then returned together with the element in question.
%% If there's no such element, this returns `undefined' instead.
-spec split_by(List, fun((Element) -> boolean())) -> {List, Element, List} when
    List :: [Element],
    Element :: term().
split_by(List, Fun) when is_list(List) andalso is_function(Fun, 1) ->
    split_by(List, Fun, []).

split_by([], _Fun, Acc) ->
    {lists:reverse(Acc), undefined, []};
split_by([Head | Tail], Fun, Acc) ->
    case Fun(Head) of
        true -> {lists:reverse(Acc), Head, Tail};
        false -> split_by(Tail, Fun, [Head | Acc])
    end.

%% @doc Returns the MFA tuple for the given `fun'.
fun_to_mfa(Fun) when is_function(Fun) ->
    #{
        module := Module,
        name := Name,
        arity := Arity
    } = maps:from_list(erlang:fun_info(Fun)),
    {Module, Name, Arity}.

%% @doc Recompiles the given module with `export_all' set, allowing
%% you to call private functions. This uses the `debug_info' in the beam
%% file, so no source code needed.
export_all(Module) when is_atom(Module) ->
    Options = proplists:get_value(options, Module:module_info(compile)),
    {Module, Beam0, Beamfile} = code:get_object_code(Module),
    {ok, {_, [{abstract_code, {_, AST}}]}} = beam_lib:chunks(Beam0, [abstract_code]),
    {ok, Module, Beam1, _Warnings} = compile:forms(
        AST,
        [export_all, nowarn_export_all, return | Options]
    ),
    code:load_binary(Module, Beamfile, Beam1).

%% @doc Works like {@link merl:quote/1}, but also accepts
%% {@link erl_syntax:string/1 .string nodes}. Instead of throwing
%% `{error, Reason}', it returns a valid
%% <a href="https://erlang.org/doc/man/erl_parse.html#errorinfo">
%% error info</a>.
%%
%% The first argument is a file string (or node) and is used for the
%% <a href="https://erlang.org/doc/man/erl_parse.html#errorinfo">
quote(File0, Line0, Source0) ->
    File1 = safe_value(File0),
    Line1 = safe_value(Line0),
    Source1 = safe_value(Source0),
    try merl:quote(Line1, Source1) of
        AST ->
            {ok, AST}
    catch
        throw:{error, SyntaxError} ->
            {error, {File1, {Line1, ?MODULE, SyntaxError}}}
    end.

%% @private
safe_value(Node) when is_tuple(Node) ->
    merlin_lib:value(Node);
safe_value(Value) ->
    Value.

eunit(Tests) ->
    eunit:test([
        {timeout, 60 * 60, Test}
     || Test <- Tests
    ]).
