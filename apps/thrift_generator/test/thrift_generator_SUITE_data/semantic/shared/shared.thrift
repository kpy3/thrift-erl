namespace erl shared

enum Numberz { ONE = 1, TWO }

struct Inner { 1: string name }

exception Boom { 1: string message }

service BaseService {
  void ping(),
  i32 area(1: i32 w, 2: i32 h) throws (1: Boom b)
}
