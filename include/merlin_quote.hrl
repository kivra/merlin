-ifndef(MERLIN_QUOTE).
-define(MERLIN_QUOTE, true).

-compile({parse_transform, merlin_quote_transform}).

%% Equivalent with {@link merl:Q/1} but can be used in more places.
%% @See merlin_quote_transform
-define(QQ(Forms), {'MERLIN QUOTE MARKER', ?FILE, ?LINE, Forms}).

%% Same as {@link QQ/1} but also sets the {@link erl_anno} of the resulting
%% node using the given location.
%% @see merlin_quote_transform:set_location/2
-define(QQ(Location, Forms),
    merlin_quote_transform:set_location(Location, ?QQ(Forms))
).

%% We call the merl transform ourselves
-ifndef(MERL_NO_TRANSFORM).
-define(MERL_NO_TRANSFORM, true).
-endif.

-endif.
