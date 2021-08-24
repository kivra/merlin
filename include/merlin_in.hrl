-ifndef(MERLIN_IN).
-define(MERLIN_IN, true).

-compile({parse_transform, merlin_in_transform}).

-define(in, and merlin_in_transform:'IN'() and).

-define(in(Expression), and merlin_in_transform:'IN'(??Expression)).

-define(in(High, Low), in(High..Low)).

-include("merlin_oneof.hrl").

-endif.
