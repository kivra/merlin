-module(merlin_auto_increment_bindings_example).

-compile([export_all, nowarn_export_all]).

-include("merlin_auto_increment_bindings.hrl").

simple() ->
    Map@ = #{},
    Map@ = Map_#{first => 1},
    Map@ = Map_#{second => 2},
    Map@ = Map_#{third => 3},
    Map@ = Map_#{first => "abc"},
    Map_.

match() ->
    Author@ = users:get(11),
    Author@ = users:add_posts(Author_),
    %% Always ok to use trailing underscore
    Comment_ = comments:get(31),
    case Comment_ of
        %% This however would not compile, as it's ambiguous if it
        %% should be incremented or refer to the current number.
        %% #{ author := Author } ->
        #{author := Author_} ->
            maps:get(posts, Author_);
        _ ->
            []
    end.

complex(Ctx@, #{first_name := FirstName, last_name := LastName} = User@) when
    not is_map_key(id, User_)
->
    Id@ = db:generate_id(),
    User@ = User_#{id => Id_, name => io_lib:format("~s ~s", [FirstName, LastName])},
    case db:save(Ctx_, User_) of
        {ok, {Ctx@, User@}} ->
            {Ctx_, User_};
        {error, {unique_violation, Id_}} ->
            Id@ = db:generete_id(),
            %% Try one extra time
            complex(Ctx_, User_#{id := Id_});
        {error, _} = Error ->
            Error
    end;
complex(Ctx@, #{first_name := FirstName, last_name := LastName} = User@) ->
    User@ = User_#{name => io_lib:format("~s ~s", [FirstName, LastName])},
    case db:save(Ctx_, User_) of
        {ok, {Ctx@, User@}} ->
            {Ctx_, User_};
        {error, _} = Error ->
            Error
    end.
