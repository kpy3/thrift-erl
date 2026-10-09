namespace erl nativedemo

// Generated under --repr native: every definition without an explicit
// erl.struct_type materializes as a native-representation struct —
// runtime-minted records, no declared tuples, decode default `native`.

struct Point {
  1: i32 x,
  2: string label
}

exception Oops {
  1: string why
}

service NatSvc {
  Point reflect(1: Point p) throws (1: Oops o),
  i32 area(1: i32 w, 2: i32 h)
}
