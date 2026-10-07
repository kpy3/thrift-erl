# thrift-generator

Альтернативный генератор Apache Thrift и runtime-библиотека для Erlang.
Принимает Thrift IDL, генерирует Erlang-код типов, клиента и сервера,
совместимый по бинарному протоколу со штатной реализацией Apache Thrift
(проверяется golden-тестами интеропа в обе стороны против официального
runtime 0.25.0 на buffered и framed транспорте).

## Структура

```
apps/thrift_generator/   IDL-парсер (leex/yecc), семантика, эмиттер, CLI
apps/thrift_erl/         runtime: бинарный протокол, транспорты, сервер, клиент
apps/rebar3_thrift/      rebar3-плагин (провайдер thrift)
vendor/apache-thrift-erl официальный Apache Thrift Erlang runtime (0.25.0),
                         только test-профиль — golden-фикстура интеропа
```

Сгенерированный код зависит только от `thrift_erl` (kernel + stdlib).
Генератор никогда не является runtime-зависимостью.

## Сборка и тесты

Требуется Erlang/OTP 28+.

```
rebar3 compile
rebar3 eunit        # юниты + 5 PropEr-свойств кодека
rebar3 ct           # loopback-сценарии + golden interop
rebar3 dialyzer
rebar3 xref
rebar3 fmt
```

## CLI

```
rebar3 as prod escriptize
_build/prod/bin/thrift_generator generate my_api.thrift -o src
```

Генерирует `<mod>_types.erl` (один на IDL-файл) и по три модуля на
сервис: `<Svc>_client.erl`, `<Svc>_server.erl`, `<Svc>_handler.erl`.

## Плагин rebar3

В `rebar.config` проекта-потребителя:

```erlang
{plugins, [rebar3_thrift]},

{thrift, [
    {files, ["src/my_api.thrift"]},
    {out_dir, "src"}
]},

%% регенерировать перед каждой компиляцией:
{provider_hooks, [{pre, [{compile, {default, thrift}}]}]}
```

Для локальной разработки плагин подключается через `_checkouts/`:

```
mkdir -p _checkouts
ln -s /path/to/thrift-generator/apps/rebar3_thrift _checkouts/rebar3_thrift
ln -s /path/to/thrift-generator/apps/thrift_generator _checkouts/thrift_generator
```

## Пример

IDL (`src/ping.thrift`):

```thrift
namespace erl ping.api

struct PingRequest {
  1: required string message
}

struct PingReply {
  1: required string message,
  2: i64 at_millis
}

exception NoSuchMessage {
  1: string text
}

service Ping {
  PingReply ping(1: PingRequest request) throws(1: NoSuchMessage err),
  oneway void poke()
}
```

Обработчик (records объявлены в `<mod>_types.erl`, имена — из имён
структур в нижнем регистре):

```erlang
-module(ping_handler).
-behaviour('Ping_handler').

-export([ping/1, poke/1]).

ping(#pingrequest{message = <<"bad">>}) ->
    {error, {exception, <<"NoSuchMessage">>, #nosuchmessage{text = <<"nope">>}}};
ping(#pingrequest{message = Msg}) ->
    {ok, #pingreply{message = <<"pong: ", Msg/binary>>, at_millis = 0}}.

poke(_Req) -> {ok, undefined}.
```

Сервер и клиент:

```erlang
{ok, Server} = 'Ping_server':start_link(#{port => 9090, handler => ping_handler}),
{ok, Client} = 'Ping_client':start_link(#{host => "127.0.0.1", port => 9090}),
{ok, #pingreply{message = <<"pong: hi">>}} =
    'Ping_client':ping(Client, #pingrequest{message = <<"hi">>}),
%% объявленное исключение — типизированное:
{error, {exception, <<"NoSuchMessage">>, #nosuchmessage{}}} =
    'Ping_client':ping(Client, #pingrequest{message = <<"bad">>}),
ok = 'Ping_client':stop(Client),
ok = 'Ping_server':stop(Server).
```

Опции `start_link` (map при создании, не app env):

- `transport` — `framed` (по умолчанию) или `buffered`;
- сервер: `port`, `handler`, `max_frame_size`, `max_connections`,
  `timeout`, `backlog`;
- клиент: `host`, `port`, `recv_timeout`.

## Аннотации кодогенерации

- `erl.struct_type = "map"` — структура эмитится как map
  (+ `erl.struct_type.map.key_type = "atom"` для атомарных ключей);
  по умолчанию — records;
- `erl.type = "nominal"` у typedef — `-nominal` вместо alias;
- `erl.*`-аннотации фильтруются при парсинге, прочие сохраняются.

Интроспекция в духе официального генератора: `struct_info/1`,
`enum_info/1`, `function_info/2`, `record_fields/1`, `service_info/0`
в `<mod>_types.erl`.

## Лицензия

Apache License 2.0. Лексер/парсер унаследованы из Apache Thrift
(Pinterest, 2017) с сохранением атрибуции; vendored-фикстура
`vendor/apache-thrift-erl` — Apache Thrift 0.25.0 (см.
`vendor/apache-thrift-erl/README-VENDORED.md`).
