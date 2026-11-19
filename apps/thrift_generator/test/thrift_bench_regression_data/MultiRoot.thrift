namespace erl multiroot

include "MultiIncluded.thrift"

struct Outer {
    1: required list<MultiIncluded.Inner> items,
}
