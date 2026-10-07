namespace erl cycle_b

include "cycle_a.thrift"

struct B { 1: cycle_a.A a }
