-ifndef(MERLIN_QUOTE).
-define(MERLIN_QUOTE, true).

-compile({parse_transform, merlin_quote_transform}).

%% Equivalent with {@link merl:Q/1} but can be used in more places.
%% @See merlin_quote_transform
-define(Q(Forms), {'MERLIN QUOTE MARKER', ?FILE, ?LINE, Forms}).

%% Backwards compability for < 2.0.1
-ifndef(MERLIN_NO_QQ).
-define(QQ(Forms), ?Q(Forms)).
-endif.

-endif.
