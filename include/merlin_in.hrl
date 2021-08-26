-ifndef(MERLIN_IN).
-define(MERLIN_IN, true).

%% Allow mixing this and `oneof' macros without running the parse transform
%% twice
-ifndef(MERLIN_ONEOF).
-compile({parse_transform, merlin_in_transform}).
-endif.

-define(in, and merlin_in_transform:'IN'() and).

-define(in(Expression), and merlin_in_transform:'IN'(??Expression)).

-define(in(High, Low), in(High..Low)).

-endif.
