namespace erl qualified_includer

include "includee.thrift"

/// References spell the qualifier both ways on purpose: `includee' is
/// the included file's base name (the Apache Thrift qualification),
/// `qualified_includee' is the target's module key.

const i64 Cap = includee.LIMIT

struct Holder {
  1: required includee.Payload payload,
  2: includee.Color color,
  3: includee.Stamp at,
  4: qualified_includee.Payload by_module
}
