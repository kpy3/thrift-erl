-module(thrift_generator).

-export([tokens/1, ast/1]).

tokens(Filename) ->
    maybe
        {ok, Data} ?= file:read_file(Filename),
        DataStr = binary:bin_to_list(Data),
        Basename = filename:basename(Filename),
        DataWithFilename = DataStr ++ lists:concat(["\n__file__ \"", Basename, "\""]),
        thrift_lexer:string(DataWithFilename)
    end.

ast(Tokens) ->
    thrift_parser:parse(Tokens).