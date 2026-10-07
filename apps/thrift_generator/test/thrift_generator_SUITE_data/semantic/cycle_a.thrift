namespace erl cycle_a

include "cycle_b.thrift"

struct A { 1: cycle_b.B b }
