# merlin

Parse transform library to make writing those a breeze. It builds on top of
[merl](https://erlang.org/doc/man/merl.html), and takes inspiration of
[parse_trans](https://github.com/uwiger/parse_trans/).

The latter might have support for carrying a state during transform, but it's
not documented. The one function that is only supports simple transforms, and
require intimate knowledge about the Erlang AST. While I do think knowing the
AST is good, `merl` makes it much easier to work with, and it's a shame it
doesn't fit into `parse_trans` so well.

Merlin rectifies that by embracing `merl` and provides a small parse
transform to extend its `case` matching to function heads.

```erlang
-include_lib("merlin/include/merlin_quote.hrl").

parse_transform(Forms, CompileOptions) ->
    {Forms1, _State1} = merlin:transform(Forms, fun transform/3, #{
        options => CompileOptions
    }),
    merlin:return(Forms1).

transform(enter, ?QQ("_@Var"), State) when erl_syntax:type(Var) =:= variable ->
    ?QQ("_@Var = 123");
transform(_, _, _) ->
    continue.
```

This example also demonstrate how to use `merlin:transform/3`. The idea is to
thread the given transformer function through all AST nodes while carrying a
user provided state. Depending on the return value, the current node is
either replaced, kept as is or deleted. In fact, you can return more then one
node, which is nigh impossible with a plain transform.

In all of the above cases, you can also return an updated state. Thus you can
easily keep track of the current set of variables, or how many times a
certain functions is called etc.

`merlin_lib` provide some helpers for common tasks, like finding the
`-module` attribute, or generating new, unique, variables to avoid accidental
`badmatch` errors.

## Developing

This uses `rebar3`, and contains a `Makefile` for some common tasks. It also
uses [logger](https://erlang.org/doc/man/logger.html), with a sample config.
Once copied you can tweak it to log what's happening under the hood.

```console
$ make examples
```
