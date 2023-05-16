%%% @doc
%%% @private
%%% @end

%%%_* Module declaration =====================================================
-module(merlin_internal).

%%%_* Exports ================================================================
-export([
    eunit/1,
    export_all/1,
    format/1,
    format/2,
    format_forms/1,
    format_stack/1,
    format_using_erl_error/2,
    fun_to_mfa/1,
    log_macro/4,
    print_merl_match_failure/3,
    print_merl_equal_failure/3,
    print_stacktrace/1,
    quote/3,
    split_by/2,
    write_log_file/0
]).

-ifdef(MERLIN_INTERNAL_EXPORT_ALL).
-compile([export_all, nowarn_export_all]).
-endif.

%%%_* Includes ===============================================================
-include("log.hrl").

%% @hidden
%% @doc This is a helper for the ?level(A, B, C) macros.
%% Unfortunately it can't be inlined because dialyzer complains about
%% "Guard test ... can never succeed". Which is technically true, but not
%% relevant in the context of a macro designed to be called in multiple
%% different ways.
-spec log_macro(logger:level(), term(), term(), logger:metadata()) -> ok.
log_macro(Level, Format, Metadata, MacroMetadata) when
    (not is_function(Format)) andalso is_map(Metadata)
->
    logger:log(Level, Format, maps:merge(MacroMetadata, Metadata));
log_macro(Level, A, B, Metadata) ->
    logger:log(Level, A, B, Metadata).

%% @hidden
write_log_file() ->
    %% Only flush if our logger is active
    case lists:member(debug_log, logger:get_handler_ids()) of
        true -> logger_std_h:filesync(debug_log);
        false -> ok
    end.

%% @equiv format(SourceOrNodeOrNodes, #{})
format(SourceOrNodeOrNodes) ->
    format(SourceOrNodeOrNodes, #{}).

%% @doc Formats the given `Source', {@link merlin:ast(). `Node'}, or `Nodes'
%% using {@link erlfmt}.
-spec format(string() | merlin:ast() | [merlin:ast()], Options) -> string() when
    Options :: #{
        %% Used by {@link erlfmt} to provide better error messages
        filename => file:filename(),
        %% Defaults to the current terminal width
        linewidth => pos_integer()
    }.
format([], _Options) ->
    "";
format(Source, Options0) when is_integer(hd(Source)) ->
    Options1 = default_formatting_options(Options0),
    format_string(Source, Options1);
format(Nodes, Options0) when is_list(Nodes) ->
    Options1 = default_formatting_options(Options0),
    lists:join($\n, [format_node(Node, Options1) || Node <- merlin_lib:flatten(Nodes)]);
format(Node, Options0) ->
    Options1 = default_formatting_options(Options0),
    format_node(Node, Options1).

%% @private
default_formatting_options(Options) ->
    Linewidth1 = case Options of
        #{linewidth := Linewidth0} ->
            Linewidth0;
        _ ->
            case io:columns() of
                {ok, Value} -> Value;
                {error, enotsup} -> 120
            end
    end,
    maps:to_list(
        maps:merge(
            #{
                %% erlfmt
                linewidth => Linewidth1,
                %% erl_prettypr
                paper => Linewidth1,
                ribbon => Linewidth1 - 15,
                encoding => utf8,
                %% erl_pp
                print_width => Linewidth1
            },
            Options
        )
    ).

%% @private
format_string(Source, Options) ->
    {ok, Formatted, _Warnings} = erlfmt:format_string(
        unicode:characters_to_list(string:replace(Source, <<"\n">>, <<" ">>, all)),
        Options
    ),
    Formatted.

%% @private
format_node(Node0, Options0) ->
    Node1 = merlin:revert(Node0),
    Source = erl_prettypr:format(Node1, Options0),
    Options1 =
        case merlin_lib:get_annotation(Node0, file, none) of
            none -> Options0;
            File -> lists:keystore(filename, 1, Options0, {filename, File})
        end,
    format_string(Source, Options1).

%% @doc Returns a {Format, Arguments} pair with the given `Prefix' and `Forms'.
%%
%% This first tries to render the given 'Forms' as Erlang syntax using
%% {@link format/1}, {@link merlin:revert/1. reverting} as needed, and finally
%% just using `io_lib:format("~tp", [Forms])'.
-spec format_forms({string(), merlin:ast() | [merlin:ast()] | term()}) ->
    {string(), [iolist()]}.
format_forms({Prefix, Forms}) when is_list(Prefix) ->
    {"~s~n~s", [
        Prefix,
        lists:join($\n, [
            try
                format(Form)
            catch
                _:_ ->
                    io_lib:format("~tp", [Form])
            end
         || Form <- lists:flatten([Forms])
        ])
    ]};
format_forms(Forms) ->
    format_forms({"", Forms}).

%% @doc Used by `?assertMerlMatch' to print a useful error message on failure.
print_merl_match_failure(GuardSource, Actual, Options) ->
    FormattedActual = format_source_lines(Actual, Options),
    {match, [Macro, MacroArguments]} = re:run(
        GuardSource,
        %% Matches ?Q(...) and ?QUOTE(...) calls
        "\\? *(Q|QUOTE) *\\( *(.+) *\\)$",
        [{capture, all_but_first, list}]
    ),
    FormattedMacro =
        case Macro of
            "Q" ->
                format(MacroArguments, Options);
            "QUOTE" ->
                %% The ?QUOTE needs to be completed with a period, or else
                %% erlfmt can't parse it.
                format(MacroArguments ++ ".", Options)
        end,
    io:format(
        "assertMerlMatch failed\nDifference:\n~ts\n", [
            lists:map(
                fun format_diff/1,
                lists:flatten(diff_words(tdiff:diff(FormattedMacro, FormattedActual)))
            )
        ]
    ).

%% @doc Used by `?assertMerlEqual' to print a useful error message on failure.
print_merl_equal_failure(Expected, Actual, Options) ->
    FormattedExpected = format_source_lines(Expected, Options),
    FormattedActual = format_source_lines(Actual, Options),
    io:format(
        "assertMerlEqual failed\nDifference:\n~ts\n", [
            lists:map(
                fun format_diff/1,
                lists:flatten(diff_words(tdiff:diff(FormattedExpected, FormattedActual)))
            )
        ]
    ).

format_source_lines(SourceOrNodeOrNodes, Options) ->
    Source0 = format(SourceOrNodeOrNodes, Options),
    Source1 = string:trim(Source0),
    Lines0 = string:split(Source1, <<"\n">>, all),
    Lines1 = [unicode:characters_to_list([Line, "\n"]) || Line <- Lines0],
    Lines1.

diff_words([]) ->
    [];
diff_words([{del, Deleted}, {ins, Inserted} | Tail]) ->
    WordDiff = tdiff:diff(
        unicode:characters_to_list(Deleted),
        unicode:characters_to_list(Inserted)
    ),
    [ignore_whitespace(WordDiff), diff_words(Tail)];
diff_words([Edit | Tail]) ->
    [Edit | diff_words(Tail)].

ignore_whitespace([]) ->
    [];
ignore_whitespace([{del, Deleted}, {ins, Inserted} | Tail]) ->
    case string:trim(Deleted) =:= string:trim(Inserted) of
        true ->
            [{eq, Deleted} | ignore_whitespace(Tail)];
        false ->
            [{del, Deleted}, {ins, Inserted}, ignore_whitespace(Tail)]
    end;
ignore_whitespace([Edit | Tail]) ->
    [Edit | ignore_whitespace(Tail)].

format_diff({eq, String}) ->
    String;
format_diff({del, Deleted}) ->
    color:on_red(Deleted);
format_diff({ins, Inserted}) ->
    case string:trim(Inserted) of
        "" -> Inserted;
        _ -> color:on_green(Inserted)
    end.

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

print_stacktrace({current_stacktrace, StackTrace}) ->
    io:format("~s~n", [format_stack(StackTrace)]);
print_stacktrace(Forms) ->
    {Format, Args} = format_forms(Forms),
    io:format(Format, Args).

%% @doc Splits `List' using `Fun' at the element for which it returns `true'.
%% That element then returned together with the element in question.
%% If there's no such element, this returns `undefined' instead.
-spec split_by(List, fun((Element) -> boolean())) -> {List, Element, List} when
    List :: [Element],
    Element :: term().
split_by(List, Fun) when is_list(List) andalso is_function(Fun, 1) ->
    split_by(List, Fun, []).

%% @private
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
%% {@link erl_syntax:string/1. string nodes}. Instead of throwing
%% `{error, Reason}', it returns a valid
%% <a href="https://erlang.org/doc/man/erl_parse.html#errorinfo">
%% error info</a>.
%%
%% The first argument is a file string (or node) and is used for the
%% <a href="https://erlang.org/doc/man/erl_parse.html#errorinfo">`errorinfo'</a>
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
