%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Helpers for working with errors.
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%_* Module declaration =====================================================
-module(merlin_error).

%%%_* Exports ================================================================
%%%_ * API -------------------------------------------------------------------
-export([
    into_error_marker/2
]).

%%%_ * Callbacks -------------------------------------------------------------
-export([
    format_error/1,
    format_error/2
]).

%%%_* Types ------------------------------------------------------------------

%%%_* Includes ===============================================================

%%%_* Macros =================================================================

%%%_* Types ==================================================================

%%%_* Code ===================================================================
%%%_ * API -------------------------------------------------------------------
%% @doc Returns a
%% <a href="https://erlang.org/doc/man/erl_parse.html#errorinfo">
%% error info</a> with the given reason and location taken from the second
%% argument. If it is a stacktrace, the latter is taken from the first frame.
%% Otherwise it is assumed to be a {@link merlin:ast(). syntax node} and its
%% location is used.
-spec into_error_marker(Reason, Stacktrace | Node) -> merlin:error_marker() when
    Reason :: term(),
    Stacktrace :: erlang:stacktrace(),
    Node :: merlin:ast().
into_error_marker(Reason, [{_Module, _Function, _ArityOrArguments, Location} | _]) ->
    {file, File} = lists:keyfind(file, 1, Location),
    {line, Line} = lists:keyfind(line, 1, Location),
    Anno = erl_anno:new(Line),
    {error, {File, {Anno, ?MODULE, Reason}}};
into_error_marker(Reason, Node) when is_tuple(Node) ->
    File1 =
        case merlin_annotations:get(Node, file) of
            undefined ->
                case erlang:get(file) of
                    undefined -> none;
                    File0 -> File0
                end;
            File0 ->
                File0
        end,
    Anno = erl_syntax:get_pos(Node),
    {error, {File1, {Anno, ?MODULE, Reason}}}.

%%%_ * Callbacks -------------------------------------------------------------
%% @doc Callback for formatting error messages from this module
%%
%% @see erl_parse:format_error/1
-spec format_error(term()) -> string().
format_error(Message0) ->
    Message1 =
        case io_lib:deep_char_list(Message0) of
            true -> Message0;
            false -> io_lib:format("~tp", [Message0])
        end,
    Message3 =
        case re:run(Message1, "^\\d+: (.+)$", [{capture, all_but_first, list}]) of
            {match, [Message2]} -> Message2;
            nomatch -> Message1
        end,
    unicode:characters_to_list(Message3).

%% @doc Callback for formatting error messages for merlin's modules.
%%
%% See <a href="https://www.erlang.org/eeps/eep-0054">EEP 54</a>
-spec format_error(Reason, erlang:stacktrace()) -> ErrorInfo when
    Reason :: term(),
    ErrorInfo :: #{
        pos_integer() | general | reason => string()
    }.
format_error(badarg, [{merlin_annotations, delete, [_Node, line], _Location} | _]) ->
    #{2 => "can't remove the line annotation"};
format_error(badarg, [{merlin_annotations, delete, [_Node, location], _Location} | _]) ->
    #{2 => "can't remove the location annotation"};
format_error({badkey, Key}, [{merlin_annotations, get, [_Node, Key], _Location} | _]) ->
    #{2 => "not present in node"};
format_error({badvalue, Node}, [{merlin_lib, value, [Node], Location} | _]) ->
    {error_info, ErrorInfo} = lists:keyfind(error_info, 1, Location),
    case ErrorInfo of
        #{cause := unknown_type} ->
            #{1 => "unknown type"};
        #{cause := not_literal} ->
            #{1 => "not a literal node"}
    end;
format_error(Reason, [{merlin_module, find_source, [_Module], Location} | _]) ->
    {error_info, ErrorInfo} = lists:keyfind(error_info, 1, Location),
    case ErrorInfo of
        #{cause := {code, ensure_loaded}} ->
            case Reason of
                badfile ->
                    #{1 => "incorrect object code or wrong module name"};
                on_load_failure ->
                    #{1 => "-on_load_function failed"}
            end
    end;
format_error(_, _) ->
    #{}.

%%%_* Private ----------------------------------------------------------------

%%%_* Tests ==================================================================
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-include_lib("syntax_tools/include/merl.hrl").
-include("assertions.hrl").

into_error_marker_test_() ->
    %% Without this acrobatics, the Erlang compiler will warn that the
    %% division below will always fail.
    {One, []} = string:to_integer("1"),
    {Zero, []} = string:to_integer("0"),
    maps:to_list(#{
        "from stacktrace" => fun() ->
            try
                One / Zero
            catch
                error:badarith:Stacktrace ->
                    Line = ?LINE - 3,
                    ErrorMarker = into_error_marker(badarith, Stacktrace),
                    ?assertEqual(
                        {error, {?FILE, {Line, ?MODULE, badarith}}}, ErrorMarker
                    )
            end
        end,
        "from syntax node" => maps:to_list(#{
            "without file" => fun() ->
                Node = ?Q("some_term"),
                Line = ?LINE - 1,
                ErrorMarker = into_error_marker(badarith, Node),
                ?assertEqual(
                    {error, {none, {Line, ?MODULE, badarith}}}, ErrorMarker
                )
            end,
            "with file in process dictionary" => fun() ->
                Node = ?Q("some_term"),
                Line = ?LINE - 1,
                erlang:put(file, ?FILE),
                ErrorMarker =
                    try
                        into_error_marker(badarith, Node)
                    after
                        erlang:erase(file)
                    end,
                ?assertEqual(
                    {error, {?FILE, {Line, ?MODULE, badarith}}},
                    ErrorMarker
                )
            end,
            "with file" => fun() ->
                Node0 = ?Q("some_term"),
                Line = ?LINE - 1,
                Node1 = erl_syntax:set_pos(
                    Node0, erl_anno:set_file(?FILE, erl_syntax:get_pos(Node0))
                ),
                ErrorMarker = into_error_marker(badarith, Node1),
                ?assertEqual(
                    {error,
                        {?FILE, {
                            [{file, ?FILE}, {location, Line}], ?MODULE, badarith
                        }}},
                    ErrorMarker
                )
            end
        })
    }).

format_error_message_test_() ->
    maps:to_list(#{
        "string reason" => fun() ->
            ?assertEqual("some error", format_error(["some", $\s, "error"]))
        end,
        "term reason" => fun() ->
            ?assertEqual("{some,error}", format_error({some, error}))
        end,
        "merl syntax error" => fun() ->
            try
                merl:quote("foo(")
            catch
                throw:{error, Message} ->
                    ?assertRegexpMatch("^syntax error", format_error(Message))
            end
        end
    }).

format_error_test_() ->
    maps:to_list(#{
        "merlin_annotations:delete line" => fun() ->
            Node = ?Q("some_term"),
            Line = ?LINE - 1,
            ErrorInfo = format_error(badarg, [
                {merlin_annotations, delete, [Node, line], [
                    {line, Line}, {file, ?FILE}
                ]}
            ]),
            ?assertEqual(
                #{2 => "can't remove the line annotation"}, ErrorInfo
            )
        end,
        "merlin_annotations:delete location" => fun() ->
            Node = ?Q("some_term"),
            Line = ?LINE - 1,
            ErrorInfo = format_error(badarg, [
                {merlin_annotations, delete, [Node, location], [
                    {line, Line}, {file, ?FILE}
                ]}
            ]),
            ?assertEqual(
                #{2 => "can't remove the location annotation"}, ErrorInfo
            )
        end,
        "merlin_annotations:get missing key" => fun() ->
            Node = ?Q("some_term"),
            Line = ?LINE - 1,
            ErrorInfo = format_error({badkey, line}, [
                {merlin_annotations, get, [Node, line], [{line, Line}, {file, ?FILE}]}
            ]),
            ?assertEqual(
                #{2 => "not present in node"}, ErrorInfo
            )
        end,
        "merlin_lib:value unknown type" => fun() ->
            Node = ?Q("some_term"),
            Line = ?LINE - 1,
            ErrorInfo = format_error({badvalue, Node}, [
                {merlin_lib, value, [Node], [
                    {line, Line},
                    {file, ?FILE},
                    {error_info, #{cause => unknown_type}}
                ]}
            ]),
            ?assertEqual(
                #{1 => "unknown type"}, ErrorInfo
            )
        end,
        "merlin_lib:value not a literal node" => fun() ->
            Node = ?Q("some_term"),
            Line = ?LINE - 1,
            ErrorInfo = format_error({badvalue, Node}, [
                {merlin_lib, value, [Node], [
                    {line, Line},
                    {file, ?FILE},
                    {error_info, #{cause => not_literal}}
                ]}
            ]),
            ?assertEqual(
                #{1 => "not a literal node"}, ErrorInfo
            )
        end,
        "merlin_module:find_source badfile" => fun() ->
            ErrorInfo = format_error(badfile, [
                {merlin_module, find_source, [some_module], [
                    {line, ?LINE},
                    {file, ?FILE},
                    {error_info, #{cause => {code, ensure_loaded}}}
                ]}
            ]),
            ?assertEqual(
                #{1 => "incorrect object code or wrong module name"}, ErrorInfo
            )
        end,
        "merlin_module:find_source on_load_failure" => fun() ->
            ErrorInfo = format_error(on_load_failure, [
                {merlin_module, find_source, [some_module], [
                    {line, ?LINE},
                    {file, ?FILE},
                    {error_info, #{cause => {code, ensure_loaded}}}
                ]}
            ]),
            ?assertEqual(
                #{1 => "-on_load_function failed"}, ErrorInfo
            )
        end,
        "otherwise" => fun() ->
            ErrorInfo = format_error(badarg, [
                {some_other_merlin_module, function, [], [{line, ?LINE}, {file, ?FILE}]}
            ]),
            ?assertEqual(#{}, ErrorInfo)
        end
    }).

-endif.
