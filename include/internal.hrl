-include("assertions.hrl").
-include("log.hrl").

-ifdef(NOASSERT).
-define(if_asserting(Block), ok).
-else.
%% Helper for compiling away code when assertions are disabled
-define(if_asserting(Block), Block).
-endif.

%% The macro for this transform looks like this:
%% -define(QQ(Forms), {'MERLIN QUOTE MARKER', ?FILE, ?LINE, Forms}).

%% Helper macro to allow writing inline source code instead of a string of
%% source code. Its especially nice to not having to escape double quotes.
-define(STRINGIFY(Value), ??Value).

%% Helper macro to merl quote, using ?Q/1, inline code.
%% Multiple are needed as some commas are interpreted as arguments to the
%% macro, while others are ignored. Maybe because they are nested?
%%
%% These also use the parser feature of joining string literals, e.g. if you
%% write `"foo" "bar"' it gets parsed as if you had written `"foobar"'.
%% They also append a period to finish the form, as that can't be provided
%% inside a macro call. Doing that would end the macro prematurely.
-define(QUOTE(Form), ?Q(??Form ".")).
-define(QUOTE(Form1, Form2), ?Q(??Form1 "," ??Form2 ".")).
-define(QUOTE(Form1, Form2, Form3), ?Q(??Form1 "," ??Form2 "," ??Form3 ".")).
-define(QUOTE(Form1, Form2, Form3, Form4),
    ?Q(??Form1 "," ??Form2 "," ??Form3 "," ??Form4 ".")
).

%% Replaces forms matching `SearchPattern' using `ReplacementPattern' in
%% `Forms'.
%%
%% For example, to replace calls to `my_logger:info' with a call to
%% `my_logger:log' you would do something like:
%%
%% ```
%% ?replace(Forms, "my_logger:info(_@@Args)", "my_logger:log(info, _@Args)")
%% '''
%%
%% It's a macro and not a function because it uses merls `?Q/1' macros under
%% the hood.
-define(replace(Forms, SearchPattern, ReplacementPattern),
    merlin:transform(
        Forms,
        fun
            (Phase, Form, _) when Phase =:= enter orelse Phase =:= leaf ->
                case Form of
                    ?Q(SearchPattern) -> ?Q(ReplacementPattern);
                    _ -> continue
                end;
            (_, _, _) ->
                continue
        end,
        '_'
    )
).
