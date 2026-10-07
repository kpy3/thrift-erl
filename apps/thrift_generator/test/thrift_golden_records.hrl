%% Record shapes our emitter produces for ThriftTest.thrift. Used by the
%% golden interop suite and its handler; the generated
%% `thrift_test_types` module (compiled in memory at test time) declares
%% the same records — these definitions must stay in sync with it.

-record(xtruct, {string_thing, byte_thing, i32_thing, i64_thing}).
-record(xtruct2, {byte_thing, struct_thing, i32_thing}).
-record(xception, {errorCode, message}).
-record(xception2, {errorCode, struct_thing}).
