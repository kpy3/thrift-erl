# thrift-generator

Альтернативный генератор Apache Thrift и runtime-библиотека для Erlang.
Принимает Thrift IDL, генерирует Erlang-код клиента и сервера, совместимый
по бинарному протоколу со штатной реализацией Apache Thrift. Статус: ранняя
разработка (готов фронтенд: лексер/парсер полного IDL; семантика, эмиттер и
runtime — в процессе).

## Структура

```
apps/thrift_generator/   IDL-парсер (leex/yecc), семантика, эмиттер, CLI
apps/thrift_erl/         runtime: бинарный протокол, транспорты, сервер, клиент
apps/rebar3_thrift/      rebar3-плагин
```

## Сборка и тесты

Требуется Erlang/OTP 28+.

```
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 dialyzer
rebar3 xref
rebar3 fmt
```

## Лицензия

Apache License 2.0. Лексер/парсер унаследованы из Apache Thrift
(Pinterest, 2017) с сохранением атрибуции.
