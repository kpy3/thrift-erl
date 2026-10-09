namespace erl shared

enum Numberz { ONE = 1, TWO }

# unix timestamp, microseconds since the epoch
/** A cross-module scalar alias. */
typedef i64 Timestamp

struct Inner { 1: string name }

exception Boom { 1: string message }

service BaseService {
  void ping(),
  i32 area(1: i32 w, 2: i32 h) throws (1: Boom b)
}
