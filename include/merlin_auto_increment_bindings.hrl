-ifndef(MERLIN_PIN_OPERATOR).
-define(MERLIN_PIN_OPERATOR, true).

-compile({parse_transform, merlin_auto_increment_bindings}).

-endif.
