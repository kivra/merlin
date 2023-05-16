-include("assertions.hrl").
-include("log.hrl").

-ifdef(NOASSERT).
-define(if_asserting(Block), ok).
-else.
%% Helper for compiling away code when assertions are disabled
-define(if_asserting(Block), Block).
-endif.

%% Helper macro to allow writing inline source code instead of a string of
%% source code. Its especially nice to not having to escape double quotes.
-define(STRINGIFY(Value), ??Value).

%% Helper macro to merl quote, using ?Q/1, inline code.
%% Multiple are needed as some commas are interpreted as arguments to the
%% macro, while others are ignored. Maybe because they are nested?
%%
%% These use the parser feature of joining string literals, e.g. if you
%% write `"foo" "bar"' it gets parsed as if you had written `"foobar"'.
%%
%% They also append a period to finish the form, as that can't be provided
%% inside a macro call. Doing that would end the macro prematurely.
-define(QUOTE(Form), ?Q(??Form ".")).
-define(QUOTE(Form1, Form2), ?Q(??Form1 "," ??Form2 ".")).
-define(QUOTE(Form1, Form2, Form3), ?Q(??Form1 "," ??Form2 "," ??Form3 ".")).
-define(QUOTE(Form1, Form2, Form3, Form4),
    ?Q(??Form1 "," ??Form2 "," ??Form3 "," ??Form4 ".")
).

-define(quickcheck(Property), ?quickcheck(Property, [])).

-define(quickcheck(Property, Options),
    case
        proper:quickcheck(Property, proplists:delete(comment, Options ++ [long_result]))
    of
        true ->
            ok;
        X__V ->
            error(
                {assertEqual, [
                    {module, ?MODULE},
                    {line, ?LINE},
                    {expression, ("proper:quickcheck(" ??Property ", " ??Options ")")},
                    {expected, true},
                    {value, X__V}
                    | case proplists:lookup(comment, Options) of
                        none -> [];
                        X__C -> [X__C]
                    end
                ]}
            )
    end
).

%% Poor mans `in' operator
-define(oneof(Value, Alt1, Alt2), (Value =:= Alt1 orelse Value =:= Alt2)).

%% Poor mans `in' operator
-define(oneof(Value, Alt1, Alt2, Alt3),
    (Value =:= Alt1 orelse ?oneof(Value, Alt2, Alt3))
).

%% Poor mans `in' operator
-define(oneof(Value, Alt1, Alt2, Alt3, Alt4),
    (Value =:= Alt1 orelse ?oneof(Value, Alt2, Alt3, Alt4))
).

%% Poor mans `in' operator
-define(oneof(Value, Alt1, Alt2, Alt3, Alt4, Alt5),
    (Value =:= Alt1 orelse ?oneof(Value, Alt2, Alt3, Alt4, Alt5))
).

%% Poor mans `in' operator
-define(oneof(Value, Alt1, Alt2, Alt3, Alt4, Alt5, Alt6),
    (Value =:= Alt1 orelse ?oneof(Value, Alt2, Alt3, Alt4, Alt5, Alt6))
).
