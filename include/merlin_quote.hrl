-ifndef(MERLIN_QUOTE).
-define(MERLIN_QUOTE, true).

-compile({parse_transform, merlin_quote_transform}).

-define(QQ(Forms), {'MERLIN QUOTE MARKER', ?FILE, ?LINE, Forms}).

%% We call the merl transform ourselves
-ifndef(MERL_NO_TRANSFORM).
-define(MERL_NO_TRANSFORM, true).
-endif.

-endif.
