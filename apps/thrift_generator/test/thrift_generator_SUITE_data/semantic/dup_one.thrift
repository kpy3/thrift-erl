namespace erl duplicated

include "dup_two.thrift"

struct One {
  1: i32 x,
  2: dup_two.Two other
}
