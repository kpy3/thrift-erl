namespace erl main

include "shared/shared.thrift"

const shared.Numberz KIND = shared.Numberz.ONE
const i32 BASE = 10

struct Outer {
  1: shared.Inner inner,
  2: i32 count = BASE
}

enum Color { RED = 1, GREEN, BLUE = 10 }

exception Failed { 1: string reason }

service MainService extends shared.BaseService {
  shared.Inner fetch(1: i64 id) throws (1: Failed f)
}
