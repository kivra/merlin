-module(ex).

-include("merlin_example.hrl").

% -export([main/1, wild/0, child/0]).
-compile([export_all, nowarn_export_all, nowarn_unused_vars, nowarn_unused_record]).

-type err_warn_info() :: tuple().
-type option() :: atom() | {atom(), term()} | {'d', atom(), term()}.
-type abstract_code() :: [erl_parse:abstract_form()].
-record(compile, {filename="" :: file:filename(),
		  dir=""      :: file:filename(),
		  base=""     :: file:filename(),
		  ifile=""    :: file:filename(),
		  ofile=""    :: file:filename(),
		  module=[]   :: module() | [],
		  core_code=[] :: cerl:c_module() | [],
		  abstract_code=[] :: abstract_code(), %Abstract code for debugger.
		  options=[]  :: [option()],  %Options for compilation
		  mod_options=[]  :: [option()], %Options for module_info
                  encoding=none :: none | epp:source_encoding(),
		  errors=[]     :: [err_warn_info()],
		  warnings=[]   :: [err_warn_info()],
		  extra_chunks=[] :: [{binary(), binary()}]}).

trans(enter, ?QQ("logger:log(_@Level, _@Message)"), State) -> continue;
trans(enter, ?QQ("other:call(_@Message)"), State) -> continue;
trans(exit, ?QQ("other:call(_@Message)"), State) -> continue;
trans(exit, ?QQ("_@Foo"), State) -> continue;
% trans(enter, _, ?QQ("foo")) -> continue;
% trans(?QQ("_@Foo"), ?QQ("_@Bar"), State) -> continue;
trans(_, _, []) -> continue;
trans(_, _, _) -> continue.

is_hello(Text) when Text ?in [hello, "hello", <<"hello">>] ->
    true;
is_hello(N) when is_integer(N) orelse is_float(N) ->
    ?oneof(N, [0, 1.618, 2.718, 3.14]);
is_hello(N) when 1 ?'<'(N) =< 10 ->
    true;
is_hello(_) -> false.

has_it(Map, N) when N ?in(map_get(key, Map) .. 10) ->
    true.

wild() ->
    ?with [_ ||
        {ok, Row} <- db:get(key),
        logger:info("Got ~p", [Row]),
        some:call(),
        other:call(),
        third:call(),
        Url = "https://example.com",
        more:funcs(),
        {ok, Response} <- http:get(Url),
        Columns <- io:columns(),
        _ <- something:impure(Columns),
        {Row, Response}
    ] of
        % Value -> Value
        _ -> _
    ?else
        Error -> Error
    end.

main(Args) ->
    Tuple = ?QQ("{foo, 42}"),
    ?QQ("{foo, _@Number}") = Tuple,
    _Call = ?QQ("foo:bar(_@Number)"),
    Local1 = ?add(123, 456),
    Local2 = second,
    ?abs(begin
        if map_get(Local1, Args) < Local2 ->
            "second";
        true ->
            123
        end
    end).

?def(child, begin
    ?add(1, ?add(2, 3))
end).