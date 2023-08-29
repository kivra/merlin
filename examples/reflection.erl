%%% @doc Example of using merlin for extracting info out of an AST.
%%%
%%% In this case it's about expanding the AST type itself (from
%%% {@link erl_parse}).
%%% @end
-module(reflection).

-export([
    expand_erl_parse_types/0
]).

expand_erl_parse_types() ->
    Source = merlin_lib:find_source(erl_parse),
    {ok, Forms0} = epp_dodger:parse_file(Source),
    #{
        attributes := #{
            type := #{
                abstract_form := [{abstract_form, AbstractFormUnionType, []}]
            } = Types
        }
    } = merlin:analyze(Forms0),
    ModuleForms = [
        hd(merlin_lib:get_attribute_forms(Forms0, file)),
        merlin_lib:module_form(Forms0)
        | erl_syntax:type_union_types(AbstractFormUnionType)
    ],
    {Forms1, _} = merlin:transform(
        ModuleForms,
        fun expand_erl_parse_types_transformer/3,
        #{types => Types, stack => []}
    ),
    [_File, _Module | ExpandedTypes] = merlin:return(Forms1),
    ExpandedTypeUnion = merlin:revert(erl_syntax:type_union(ExpandedTypes)),
    {attribute, 1, type, {abstract_form, ExpandedTypeUnion, []}}.

expand_erl_parse_types_transformer(
    enter, Form, #{types := Types, stack := Stack} = State
) ->
    case erl_syntax:type(Form) of
        user_type_application ->
            Name = erl_syntax:atom_value(erl_syntax:user_type_application_name(Form)),
            case ordsets:is_element(Name, Stack) of
                true ->
                    return;
                false ->
                    case Types of
                        #{Name := [{Name, Type0, Parameters}]} ->
                            Arguments = erl_syntax:user_type_application_arguments(
                                Form
                            ),
                            Mapping = maps:from_list(
                                lists:zipwith(
                                    fun(Parameter, Argument) ->
                                        {erl_syntax:variable_name(Parameter), Argument}
                                    end,
                                    Parameters,
                                    Arguments
                                )
                            ),
                            {Type1, _} = merlin:transform(
                                Type0, fun expand_parameters/3, Mapping
                            ),
                            Type2 = erl_syntax:add_ann({expanded, Name}, Type1),
                            {Type2, State#{stack := ordsets:add_element(Name, Stack)}};
                        _ ->
                            continue
                    end
            end;
        _ ->
            continue
    end;
expand_erl_parse_types_transformer(exit, Form, #{stack := Stack} = State) ->
    case merlin_annotations:get(Form, expanded, <<>>) of
        <<>> ->
            continue;
        Name ->
            {Form, State#{stack := ordsets:del_element(Name, Stack)}}
    end;
expand_erl_parse_types_transformer(_, _, _) ->
    continue.

expand_parameters(enter, Form, Mapping) ->
    case erl_syntax:type(Form) of
        variable ->
            Name = erl_syntax:variable_name(Form),
            case Mapping of
                #{Name := Argument} ->
                    Argument;
                _ ->
                    continue
            end;
        _ ->
            continue
    end;
expand_parameters(_, _, _) ->
    continue.
