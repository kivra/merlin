-module(with_statement_example).

-compile([export_all, nowarn_export_all]).

-include("merlin_with_statement.hrl").

simple() ->
    User = ?with([_ ||
        {ok, Data} ?when_ is_map(Data) <- user:new(),
        Data
    ]),
    User.

happy_paths() ->
    ?with [_ ||
        {ok, Data} <- user:new(),
        Data
    ] of
        Map when is_map(Map) ->
            Map;
        List when is_list(List) ->
            maps:from_list(List);
        _ ->
            undefined
    end.

fail_pass(Key) ->
    ?with [_ ||
        {ok, Data} <- db:get(Key),
        Data
    ] of
        Value ->
            Value
    ?else
        _ ->
            throw({badarg, Key})
    end.

complex(URI) ->
    ?with [_ ||
        {ok, Response} <- http:get(URI),
        #{ status := Status } ?when_ Status < 300 <- Response,
        Response
    ] of
        Map when is_map(Map) ->
            Map;
        List when is_list(List) ->
            maps:from_list(List);
        _ ->
            undefined
    ?else
        #{ status := 404 } ->
            throw({not_found, URI});
        _ ->
            throw({unknown_error, URI})
    end.

many() ->
    ?with [_ ||
        {ok, Post} <- posts:get(123),
        logger:info("Found post ~p", [Post]),
        #{ author_id := UserID } = Post,
        {ok, Author} <- users:get(UserID),
        logger:info("Found author ~p", [Author]),
        _ <- api:post(["/users/", UserID], logged_in),
        {ok, Post#{ author => Author }}
    ] of
        {ok, Value} -> Value
    ?else
        {error, Error} -> error(Error)
    end.
