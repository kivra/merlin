-ifndef(MERLIN_INTERNAL_HRL).
-define(MERLIN_INTERNAL_HRL, true).

-define(raise_error(Reason, Arguments),
    erlang:error(Reason, Arguments, [{error_info, #{module => merlin_error}}])
).

-define(raise_error(Reason, Arguments, Options),
    erlang:error(Reason, Arguments, [{error_info, (Options)#{module => merlin_error}}])
).

-define(is_string(Value),
    (is_list(Value) andalso length(Value) > 0 andalso is_integer(hd(Value)))
).

-define(is_non_neg_integer(Value),
    (is_integer(Value) andalso Value >= 0)
).

-define(is_pos_integer(Value),
    (is_integer(Value) andalso Value > 0)
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

%% Poor mans `in' operator
-define(oneof(Value, Alt1, Alt2, Alt3, Alt4, Alt5, Alt6, Alt7),
    (Value =:= Alt1 orelse ?oneof(Value, Alt2, Alt3, Alt4, Alt5, Alt6, Alt7))
).

%% Poor mans `in' operator
-define(oneof(Value, Alt1, Alt2, Alt3, Alt4, Alt5, Alt6, Alt7, Alt8),
    (Value =:= Alt1 orelse ?oneof(Value, Alt2, Alt3, Alt4, Alt5, Alt6, Alt7, Alt8))
).

-endif.
