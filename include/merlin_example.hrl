-include("merlin.hrl").

% -undef(in).
% -define(in, 'in' or).

-include_lib("syntax_tools/include/merl.hrl").

-define(str(Expr), ??Expr).

%% Examples

-define(add(First, Second), ?procedural(add(First, Second), begin
    % lists:map(fun(X) ->
    %     lists:map(fun(Y) ->
    %         lists:map(fun(Z) ->
    %             local(X, Y, Z)
    %         end, [3])
    %     end, [2])
    % end, [1]),
    Left = First,
    Right = Second,
    ?Q("_@Left@ + _@Right@")
end)).

-define(abs(Expr), ?procedural(abs(Expr), begin
    erl_parse:abstract(abstract(Expr))
end)).

-define(absm(Form), ?module_procedural(absm(Form), begin
    Name = erl_syntax:atom(ast),
    Node = erl_parse:abstract(?Q(?str(Form))),
    erl_syntax:set_pos(erl_syntax:attribute(Name, [Node]), ?LINE)
end)).

-define(experiment(Expr), ?procedural(experiment(Expr)), begin
    Body = abstract(Expr),
    FunctionBindings = bindings(),
    MacroBindings = erl_syntax_lib:variables(hd(Body)),
    [
        erl_parse:abstract([
            sets:to_list(FunctionBindings),
            sets:to_list(MacroBindings),
            sets:to_list(
                sets:subtract(FunctionBindings, MacroBindings)
            )
        ])
    |Body]
end)).

-define(def(Name, Value), ?module_procedural(def(Name, Value), begin
    Fn = Name,
    Body = Value,
    ?Q("'@Fn@'() -> _@Body@.")
end)).

-define(expect(Expected, Actual), ?hygienic(expect(Expected, Actual),
    begin
        Act = Actual,
        Exp = Expected,
        case Act of
            Exp -> ok;
            _ -> error({expectionFailed, [{actual, Act}, {expected, Exp}]})
        end
    end
)).

%% Python style 1 < N < 3
-define('<'(A), < A andalso A).
