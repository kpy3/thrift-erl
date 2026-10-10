# Fixture for the thrift_codec_test uuid battery: compact has no uuid
# encoding, so every path through a uuid type must fail exactly like
# the generic engine. DoubleReq declares its required fields out of
# id order (3 before 1) to pin the two different missing-field orders.

namespace erl compactuuid

struct UuidBox {
  1: optional uuid id,
  2: optional uuid prev,
  3: list<uuid> history,
  4: map<uuid, i32> tags,
  5: map<i32, uuid> tags_rev
}

struct DoubleReq {
  3: required i32 first,
  1: required string second
}
