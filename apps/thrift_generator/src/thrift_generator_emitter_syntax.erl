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

-module(thrift_generator_emitter_syntax).

-moduledoc """
The erl_syntax helper layer the emitters build forms with: module
headers, attributes, function forms, `-doc` attributes, literal terms
and the rendering to source text.

Everything here is pure and descriptor-free — no `#tg_*` records and no
resolution context — so the core emitter and the service emitter share
one vocabulary for building and printing abstract forms. Callback and
spec attributes carry raw `erl_parse' type nodes (`erl_prettypr' cannot
lay them), so those are rendered as raw forms (`erl_pp'), while
everything else stays trees.
""".

-export([
    abstract/1,
    application/3,
    attribute/2,
    base_erlang_type/1,
    doc_form/2,
    error_term_type/1,
    export_form/1,
    fn_clause/2,
    fn_form/2,
    format/1,
    function_atom/1,
    fun_type/2,
    header/2,
    map_field/2,
    moduledoc_form/1,
    nowarn_unused_record_form/0,
    ok_error_type/3,
    raw_type/1,
    record_type/1,
    remote_type/2,
    section_form/1,
    term_type/0,
    user_type/1,
    var_fun/0,
    wildcard/0
]).

-spec term_type() -> erl_syntax:syntaxTree().
term_type() ->
    {type, erl_anno:new(0), term, []}.

%% Shared spec vocabulary: `Ok | ErrorArm`, the `{error, term()}` arm,
%% and the record type of a generated record tag.

-spec ok_error_type(erl_anno:anno(), erl_syntax:syntaxTree(), erl_syntax:syntaxTree()) ->
    erl_syntax:syntaxTree().
ok_error_type(Anno, OkInner, ErrorArm) ->
    {type, Anno, union, [
        {type, Anno, tuple, [{atom, Anno, ok}, OkInner]},
        ErrorArm
    ]}.

-spec error_term_type(erl_anno:anno()) -> erl_syntax:syntaxTree().
error_term_type(Anno) ->
    {type, Anno, tuple, [{atom, Anno, error}, {type, Anno, term, []}]}.

-spec record_type(atom()) -> erl_syntax:syntaxTree().
record_type(Tag) ->
    {type, erl_anno:new(0), record, [{atom, erl_anno:new(0), Tag}]}.

%% A named type alias reference (`demo_value()'): sum unions surface in
%% generated types as aliases, and specs reference them by name.

-spec user_type(atom()) -> erl_syntax:syntaxTree().
user_type(Name) ->
    {type, erl_anno:new(0), user_type, [{atom, erl_anno:new(0), Name}]}.

-spec nowarn_unused_record_form() -> erl_syntax:syntaxTree().
nowarn_unused_record_form() ->
    erl_syntax:attribute(erl_syntax:atom(compile), [
        erl_syntax:abstract([nowarn_unused_record])
    ]).

-spec base_erlang_type(atom()) -> erl_syntax:syntaxTree().
base_erlang_type(bool) ->
    raw_type(boolean);
base_erlang_type(B) when B =:= i8; B =:= i16; B =:= i32; B =:= i64 ->
    raw_type(integer);
base_erlang_type(double) ->
    raw_type(float);
base_erlang_type(S) when S =:= string; S =:= binary; S =:= uuid ->
    raw_type(binary).

-spec raw_type(atom()) -> erl_syntax:syntaxTree().
raw_type(map) ->
    {type, erl_anno:new(0), map, any};
raw_type(Name) ->
    {type, erl_anno:new(0), Name, []}.

-spec remote_type(module(), atom()) -> erl_syntax:syntaxTree().
remote_type(Module, Name) ->
    Anno = erl_anno:new(0),
    {remote_type, Anno, [{atom, Anno, Module}, {atom, Anno, Name}, []]}.

-spec fun_type([erl_syntax:syntaxTree()], erl_syntax:syntaxTree()) -> erl_syntax:syntaxTree().
fun_type(ParamTypes, RetType) ->
    Anno = erl_anno:new(0),
    {type, Anno, 'fun', [{type, Anno, product, ParamTypes}, RetType]}.

-spec function_atom(binary()) -> atom().
function_atom(Name) ->
    binary_to_atom(Name, utf8).

%%--------------------------------------------------------------------
%% erl_syntax helpers
%%--------------------------------------------------------------------

-spec var_fun() -> fun((string()) -> erl_syntax:syntaxTree()).
var_fun() ->
    fun erl_syntax:variable/1.

%% The module header: copyright plus a plain comment naming the source
%% document. Generated modules carry no -moduledoc — the path in an
%% attribute gave the parser nothing the comment doesn't.

-spec header(module(), binary()) -> erl_syntax:forms().
header(ModuleName, SourcePath) ->
    [
        erl_syntax:comment([
            " Copyright 2026 Sergei Yelin",
            "",
            " Licensed under the Apache License, Version 2.0 (the \"License\");",
            " you may not use this file except in compliance with the License.",
            " You may obtain a copy of the License at",
            "",
            "     http://www.apache.org/licenses/LICENSE-2.0",
            "",
            " Generated from " ++ unicode:characters_to_list(SourcePath) ++ ". Do not edit."
        ]),
        erl_syntax:attribute(erl_syntax:atom(module), [erl_syntax:atom(ModuleName)])
    ].

%% The divider above every generated struct/union/exception/enum block:
%% a source comment naming the IDL construct the following forms were
%% generated from. The lines carry their own `%': prettypr prefixes
%% each comment line with exactly one.

-spec section_form(string()) -> erl_syntax:syntaxTree().
section_form(Label) ->
    Line = "---------------------------------------------------------------------",
    erl_syntax:comment(["% " ++ Line, "% " ++ Label, "% " ++ Line]).

%% The -moduledoc of a generated module that has something real to say
%% (the service handler/server/client contracts); types modules carry
%% the story in their forms and get none.

-spec moduledoc_form(binary()) -> erl_syntax:forms().
moduledoc_form(Doc) ->
    [
        erl_syntax:attribute(erl_syntax:atom(moduledoc), [
            erl_syntax:string(unicode:characters_to_list(Doc))
        ])
    ].

%% The attribute payload must be a term (tuples of {name, arity},
%% record field tuples, descriptor data) or a syntax tree; both print
%% as literal syntax.

-spec attribute(atom(), term() | erl_syntax:syntaxTree()) -> erl_syntax:syntaxTree().
attribute(Name, Payload) ->
    erl_syntax:attribute(
        erl_syntax:atom(Name),
        [abstract(Payload)]
    ).

%% -export() entries must be `arity_qualifier' trees — `abstract' tuples
%% print the same but `revert_forms' rejects them.

-spec export_form([{atom(), arity()}]) -> erl_syntax:syntaxTree().
export_form(Entries) ->
    erl_syntax:attribute(
        erl_syntax:atom(export),
        [
            erl_syntax:list([
                erl_syntax:arity_qualifier(erl_syntax:atom(F), erl_syntax:integer(A))
             || {F, A} <- Entries
            ])
        ]
    ).

-spec fn_form(atom(), [erl_syntax:syntaxTree()]) -> erl_syntax:forms().
fn_form(Name, Clauses) ->
    [erl_syntax:function(erl_syntax:atom(Name), Clauses)].

%% The -doc attribute of a generated function: the definition's IDL doc
%% comment (when it carries one) followed by the built-in explanation of
%% the generated contract. Docs land in the docs chunk, so shell_docs
%% can explain the overloaded arities (encode/2 = protocol, decode/2 =
%% representation) without the consumer reading this emitter.

-spec doc_form(binary() | undefined, binary()) -> erl_syntax:forms().
doc_form(IdlDoc, BuiltIn) ->
    Text =
        case IdlDoc of
            undefined -> BuiltIn;
            Doc -> <<Doc/binary, "\n\n", BuiltIn/binary>>
        end,
    [erl_syntax:attribute(erl_syntax:atom(doc), [erl_syntax:string(unicode:characters_to_list(Text))])].

-spec fn_clause([erl_syntax:syntaxTree()], erl_syntax:syntaxTree()) -> erl_syntax:syntaxTree().
fn_clause(Patterns, Body) ->
    erl_syntax:clause(Patterns, none, [Body]).

%% The catch-all pattern: the variable `_`, not the atom `'_'` (which
%% `abstract/1` would build and which only matches itself).

-spec wildcard() -> erl_syntax:syntaxTree().
wildcard() ->
    erl_syntax:variable("_").

%% Binaries holding printable text print as `<<"text">>' — byte-list
%% form would swamp the generated descriptors.

%% Recursive so printable binaries print as `<<"text">>' at any depth —
%% the stock `abstract/1' renders nested binaries as byte lists.

-spec abstract(term()) -> erl_syntax:syntaxTree().
abstract(Term) when is_binary(Term) ->
    case printable(Term) of
        true -> erl_syntax:binary([erl_syntax:binary_field(erl_syntax:string(unicode:characters_to_list(Term)))]);
        false -> erl_syntax:abstract(Term)
    end;
abstract(Term) when is_tuple(Term) ->
    erl_syntax:tuple([abstract(Element) || Element <- tuple_to_list(Term)]);
abstract(Term) when is_list(Term) ->
    erl_syntax:list([abstract(Element) || Element <- Term]);
abstract(Term) when is_map(Term) ->
    erl_syntax:map_expr([
        erl_syntax:map_field_assoc(abstract(Key), abstract(Value))
     || Key := Value <- Term
    ]);
abstract(Term) ->
    erl_syntax:abstract(Term).

-spec printable(binary()) -> boolean().
printable(<<>>) ->
    true;
printable(<<C, Rest/binary>>) when C >= 32, C =< 126 ->
    printable(Rest);
printable(_) ->
    false.

-spec map_field(atom(), erl_syntax:syntaxTree()) -> erl_syntax:syntaxTree().
map_field(Key, Value) ->
    erl_syntax:map_field_assoc(erl_syntax:atom(Key), Value).

-spec application(module(), atom(), [erl_syntax:syntaxTree()]) -> erl_syntax:syntaxTree().
application(Module, Name, Args) ->
    erl_syntax:application(
        erl_syntax:module_qualifier(erl_syntax:atom(Module), erl_syntax:atom(Name)),
        Args
    ).

%% Callback and spec attributes carry raw `erl_parse' type nodes
%% (`erl_prettypr' cannot lay them), so those attributes are built and
%% rendered as raw forms (`erl_pp'), while everything else stays trees.

-spec format(erl_syntax:forms()) -> binary().
format(Forms) ->
    unicode:characters_to_binary(lists:append([format_form(F) || F <- Forms])).

-spec format_form(erl_syntax:forms() | erl_syntax:syntaxTree()) -> string().
format_form({raw_text, Text}) ->
    unicode:characters_to_list(Text);
format_form({tree, _, _, _} = Tree) ->
    [erl_prettypr:format(Tree), "\n"];
format_form(RawForm) ->
    erl_pp:form(RawForm).
