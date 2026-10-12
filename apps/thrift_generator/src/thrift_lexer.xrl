%% Copyright 2017 Pinterest, Inc.
%% Copyright 2026 Sergei Yelin
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%    http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

Definitions.

WHITESPACE      = [\s\t\r\n]+
DOCLINE         = ///[^\n]*
DOCCOMMENT      = /\*\*([^*]|\*+[^*/])*\*+/
COMMENT         = //[^\n]*
HASHCOMMENT     = #[^\n]*
CCOMMENT        = /\*/*([^*/]|[^*]/|\*[^/])*\**\*/
COMMENTS        = {COMMENT}|{CCOMMENT}|{HASHCOMMENT}

INT             = [+-]?[0-9]+
HEX             = [+-]?0x[0-9A-Fa-f]+
BADDOUBLE       = [+-]?[0-9]+[eE][+-]?[0-9]+
DOUBLE          = [+-]?[0-9]+\.[0-9]+([eE][+-]?[0-9]+)?
PUNCTUATOR      = [\{\}\[\]\(\)<>,:;=\*]
STRING          = '(\\'|[^\'])*'|"(\\"|[^\"])*"
BOOLEAN         = true|false

IDENTIFIER      = [a-zA-Z_](\.[a-zA-Z_0-9]|[a-zA-Z_0-9])*

KEYWORDS1       = namespace|include|cpp_include
KEYWORDS2       = typedef|enum|union|struct|exception
KEYWORDS3       = void|bool|byte|i8|i16|i32|i64|double|string|binary|uuid|list|map|set
KEYWORDS4       = const|oneway|extends|throws|service|required|optional
KEYWORD         = {KEYWORDS1}|{KEYWORDS2}|{KEYWORDS3}|{KEYWORDS4}

RESERVED1       = BEGIN|END|__CLASS__|__DIR__|__FILE__|__FUNCTION__|__LINE__
RESERVED2       = __METHOD__|__NAMESPACE__|abstract|alias|and|args|as|assert|begin
RESERVED3       = break|case|catch|class|clone|continue|declare|def|default|del
RESERVED4       = delete|do|dynamic|elif|else|elseif|elsif|end|enddeclare|endfor
RESERVED5       = endforeach|endif|endswitch|endwhile|ensure|except|exec|finally
RESERVED6       = float|for|foreach|from|function|global|goto|if|implements|import
RESERVED7       = in|inline|instanceof|interface|is|lambda|module|native|new|next
RESERVED8       = nil|not|or|package|pass|public|print|private|protected|raise|redo
RESERVED9       = rescue|retry|register|return|self|sizeof|static|super|switch
RESERVED10      = synchronized|then|this|throw|transient|try|undef|unless|unsigned
RESERVED11      = until|use|var|virtual|volatile|when|while|with|xor|yield
RESERVED12      = {RESERVED1}|{RESERVED2}|{RESERVED3}|{RESERVED4}|{RESERVED5}
RESERVED13      = {RESERVED6}|{RESERVED7}|{RESERVED8}|{RESERVED9}|{RESERVED10}
RESERVED        = {RESERVED11}|{RESERVED12}|{RESERVED13}

Rules.

{WHITESPACE}    : skip_token.
{DOCLINE}       : {token, {doc, TokenLoc, doc_line(TokenChars)}}.
{DOCCOMMENT}    : {token, {doc, TokenLoc, doc_block(TokenChars)}}.
{COMMENTS}      : skip_token.

__file__        : {token, {file, TokenLoc}}.
{PUNCTUATOR}    : {token, {list_to_atom(TokenChars), TokenLoc}}.
{KEYWORD}       : {token, {list_to_atom(TokenChars), TokenLoc}}.

{INT}           : {token, {int, TokenLoc, list_to_integer(TokenChars)}}.
{HEX}           : {token, {int, TokenLoc, hex_to_integer(TokenChars)}}.
{DOUBLE}        : {token, {double, TokenLoc, list_to_float(TokenChars)}}.
{BADDOUBLE}     : {token, {double, TokenLoc, bad_list_to_float(TokenChars)}}.
{STRING}        : {token, {string, TokenLoc, unicode:characters_to_binary(process_string(TokenChars, TokenLen))}}.
{BOOLEAN}       : {token, {list_to_atom(TokenChars), TokenLoc}}.

{RESERVED}      : reserved_keyword_error(TokenChars, TokenLoc).

{IDENTIFIER}    : {token, {ident, TokenLoc, unicode:characters_to_binary(TokenChars)}}.

Erlang code.

hex_to_integer([$+|Chars]) ->  hex_to_integer(Chars);
hex_to_integer([$-|Chars]) -> -hex_to_integer(Chars);
hex_to_integer([$0,$x|Chars]) -> list_to_integer(Chars, 16).

% Erlang/Elixir can not parse integer significand in a float, so handle this case.

bad_list_to_float(BadFloat) ->
    {Significand, Rest} = string:to_integer(BadFloat),
    GoodFloat = io_lib:format("~b.0~s", [Significand, Rest]),
    list_to_float(lists:flatten(GoodFloat)).

% Process a quoted string by stripping its surrounding quote characters and
% expanding any escape sequences (prefixed by a \). To keep things simple,
% we're very lenient in that we allow any character to be escaped, and if the
% character isn't "special" (like \n), we just return the unescaped character.
% It might be nicer in the future to report "bad" escape characters, but that
% would involve complicating this logic to allow a top-level {error, Reason}
% result that could be returned to leex above.

process_string(S,Len)           -> process_chars(lists:sublist(S, 2, Len-2)).
process_chars([$\\,$n|Chars])   -> [$\n|process_chars(Chars)];
process_chars([$\\,$r|Chars])   -> [$\r|process_chars(Chars)];
process_chars([$\\,$t|Chars])   -> [$\t|process_chars(Chars)];
process_chars([$\\,C|Chars])    -> [C|process_chars(Chars)];
process_chars([C|Chars])        -> [C|process_chars(Chars)];
process_chars([])               -> [].

% Doc comments are kept as tokens so the parser can attach them to the
% following definition, field or enum value; ordinary comments are skipped.

doc_line("///" ++ Line) ->
    unicode:characters_to_binary(string:trim(Line)).

doc_block("/**" ++ Block) ->
    Body = lists:sublist(Block, max(length(Block) - 2, 0)),
    Lines = [strip_doc_margin(Line) || Line <- string:split(Body, "\n", all)],
    unicode:characters_to_binary(string:trim(lists:join("\n", trim_edges(Lines)))).

strip_doc_margin(Line) ->
    Stripped = string:trim(Line, leading),
    case Stripped of
        [$*, $\s | Rest] -> string:trim(Rest, trailing);
        [$* | Rest] -> string:trim(Rest, trailing);
        _ -> string:trim(Line, trailing)
    end.

trim_edges(Lines) ->
    lists:reverse(drop_empty_prefix(lists:reverse(drop_empty_prefix(Lines)))).

drop_empty_prefix([[] | Rest]) -> drop_empty_prefix(Rest);
drop_empty_prefix(Lines) -> Lines.

% Token locations are {Line, Column} pairs (the generator builds the
% rebar3-style excerpt marker on the exact column); the reserved keyword
% error carries its location the same way, landing as
% {{Line, Column}, thrift_lexer, {user, Message}}.

reserved_keyword_error(Keyword, _Loc) ->
    Message = io_lib:format(
      "cannot use reserved language keyword \"~s\"", [Keyword]),
    {error, Message}.
