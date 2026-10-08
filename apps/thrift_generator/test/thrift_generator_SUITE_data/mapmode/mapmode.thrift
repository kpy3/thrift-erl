namespace erl mapmode

// Every representation variant in one service: map mode with the
// default atom keys, map mode with binary keys, and a record-mode
// parent holding both.

struct Point { 1: i32 x, 2: i32 y } (erl.struct_type = "map")

struct BinPoint { 1: i32 x } (erl.struct_type = "map", erl.struct_type.map.key_type = "binary")

struct Nest {
  1: Point p,
  2: BinPoint b
}

exception Oops { 1: string why }

service MapSvc {
  Point reflect(1: Point p),
  Nest wrap(1: Point p),
  i32 area(1: i32 w, 2: i32 h) throws (1: Oops o)
}
