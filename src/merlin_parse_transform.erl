-module(merlin_parse_transform).

% -behaviour(parse_transform).

-export([parse_transform/2]).

% -include_lib("syntax_tools/include/merl.hrl").
-include("merlin_macros.hrl").

-compile({parse_transform, merlin_quote_transform}).

-export([do_transform/1]).

parse_transform(Forms, _Options) ->
    % io:format("merlin parse transform options: ~p~n", [Options]),
    % io:format("merlin parse transform forms: ~p~n", [Forms]),
    % io:format("Q: ~p~n", [?Q("merlin_internal:'DEFINE HYGIENIC MACRO'(_File, _Line, _Module, _BodySource, _Body)")]),
    % Name = func,
    % Args = [1,2,3],
    % Guard = [],
    % Body = {},
    % io:format("Q: ~p~n", [?Q("'_@Name'(_@Args) when _@__@Guard -> _@_Body")]),
    % ?Q("'_@Name'(_@Args) when _@__@Guard -> _@_Body") = Forms,
    % io:format("return: ~p~n", [transform(Forms)]),
    % merl:show(Forms),
    % io:format("Forms: ~p~n", [erl_syntax_lib:analyze_forms(Forms)]),
    put(merlin_state, #{}),
    parse_trans:plain_transform(fun do_transform/1, Forms).
    % parse_trans:plain_transform(fun replace_macros/1, Forms).
    % Forms.

do_transform({function, _Line, Name, Arity, _Body} = _Forms) ->
    State = get(merlin_state),
    put(merlin_state, State#{
        function => Name,
        arity => Arity
    }),
    continue;
do_transform({clause, _Line, Patterns, Guards, _Body} = Clause) ->
    State = get(merlin_state),
    put(merlin_state, State#{
        arguments => Patterns,
        guards => Guards,
        function_scope => erl_syntax_lib:variables(Clause)
    }),
    % io:format("state: ~p~n", [get(merlin_state)]),
    continue;
do_transform(?QQ(merlin_internal:'DEFINE HYGIENIC MACRO'(ArgumentsAST, _FileAST, LineAST, _ModuleAST, BodySourceAST))) ->
    BodySource = erl_syntax:concrete(BodySourceAST),
    Line = erl_syntax:concrete(LineAST),
    Body = merl:quote(Line, BodySource),
    State = get(merlin_state),
    %% Allow macro usage inside and outside functions.
    Variables = maps:get(function_scope, State, sets:new()),
    MacroVariables = maps:from_list([
        begin
            Suffix = erl_syntax_lib:new_variable_name(Variables),
            New = list_to_atom(lists:concat([Original, "_", Suffix])),
            {Original, New}
        end
    ||
        % Original <- sets:to_list(erl_syntax_lib:variables(Body))
        Original <- sets:to_list(
            sets:subtract(
                erl_syntax_lib:variables(Body),
                erl_syntax_lib:variables(ArgumentsAST)
            )
        )
    ]),
    % io:format("function: ~p~nmacro: ~p~n", [sets:to_list(Variables), sets:to_list(erl_syntax_lib:variables(Body))]),
    put(merlin_state, State#{
        macro_scope => MacroVariables
    }),
    % io:format("state: ~p~n", [get(merlin_state)]),
    % io:format("match: ~p:~p in ~p~n\t~p~n\t~p~n", [File, Line, Module, BodySource, Body]),
    [AST] = parse_trans:plain_transform(fun replace_variables/1, [Body]),
    % io:format("result: ~p~n", [AST]),
    AST;
    % ArgumentsAST;
    % BodySourceAST;
    % continue;
do_transform(_AST) ->
    % io:format("AST: ~p~n", [AST]),
    continue.

replace_variables({var, _, '_'}) -> continue;
replace_variables({var, Line, Name}) ->
    #{ macro_scope := MacroVariables } = get(merlin_state),
    case MacroVariables of
        #{ Name := New } -> {var, Line, New};
        _ -> {var, Line, Name}
    end;
replace_variables(_) -> continue.

% replace_macros({call, _, _, _} = Forms) ->
% replace_macros(Forms) ->
%% Kan ersätta try .. catch med parse_trans:is_form som gör det åt mig
%     try erl_syntax:type(Forms)
%     of _ ->
%         case Forms of
%             ?Q("'@Name'() -> _@_@Body") ->
%                 % io:format("Hello~p~n", [Name]),
%                 continue;
%             ?Q("'@Name'(_@Args) when _@__@Guards -> _@@_") ->
%                 State = get(merlin_state),
%                 put(merlin_state, State#{
%                     function => Name,
%                     arguments => Args,
%                     guards => guards
%                 }),
%                 continue;
%             ?Q("merlin_internal:'DEFINE HYGIENIC MACRO'(_@File, _@Line, _@Module, _@BodySource, _@Body)") ->
%                 io:format("hygienic: ~p~n", [get(merlin_state)]),
%                 {atom, 0, 'HYGIENIC'}
%                 ;
%             ?Q("merlin_internal:'DEFINE PROCEDURAL MACRO'(_@File, _@Line, _@Module, _@BodySource, _@Body)") ->
%                 io:format("procedural: ~p~n", [get(merlin_state)]),
%                 {atom, 0, 'PROCEDURAL'}
%                 ;
%             _ ->
%                 % io:format("unmatched form: ~p~n", [Forms]),
%                 % merl:show(Forms),
%                 continue
%         end
%     catch error:{badarg, _Arg} ->
%         continue
%     end.
% replace_macros(?QQ(merlin_internal:'DEFINE HYGIENIC MACRO'(File, Line, Module, BodySource, Body))) ->
%     io:format("wrong match~n"),
%     BodySource;
% replace_macros(_Forms) -> continue.