-module(merlin_auto_increment_bindings_example).

-compile([export_all, nowarn_export_all]).

-include("merlin_auto_increment_bindings.hrl").

simple() ->
    Map@ = #{},
    Map@ = Map_#{ first => 1 },
    Map@ = Map_#{ second => 2 },
    Map@ = Map_#{ third => 3 },
    Map@ = Map_#{ first => "abc" },
    Map_.

match() ->
    Author@ = users:get(11),
    Author@ = users:add_posts(Author_),
    %% Always ok to use trailing underscore
    Comment_ = comments:get(31),
    case Comment_ of
        %% This however would not compile
        %% #{ author := Author } ->
        #{ author := Author_ } ->
            maps:get(posts, Author_);
        _ ->
            []
    end.