namespace erl qualified_includee

/// Payload lives in a file whose module key (the erl namespace value)
/// differs from its base name: other files qualify references with
/// `includee', the include spelling, not with the module key.

struct Payload {
  1: required i64 id
}

typedef i64 Stamp

enum Color { RED = 1, BLUE = 2 }

const i64 LIMIT = 7
