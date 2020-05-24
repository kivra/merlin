-define(hygienic(ARGUMENTS, BODY),
    merlin_internal:'DEFINE HYGIENIC MACRO'(
        ARGUMENTS,
        ?FILE,
        ?LINE,
        ?MODULE_STRING,
        ??BODY
    )
).

-define(procedural(ARGUMENTS, BODY),
    merlin_internal:'DEFINE PROCEDURAL MACRO'(
        ARGUMENTS,
        ?FILE,
        ?LINE,
        ?MODULE_STRING,
        ??BODY
    )
).

-define(QQ(Forms), {'MERLIN QUOTE MARKER', ?LINE, ??Forms}).