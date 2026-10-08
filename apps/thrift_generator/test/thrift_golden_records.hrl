%% Record shapes our emitter produces for ThriftTest.thrift. Used by the
%% golden interop suite and its handler; the generated
%% `goldentest_types` module (compiled in memory at test time, renamed
%% away from the committed official code) declares the same records —
%% the `goldentest` prefix replaces the fixture's own
%% `namespace * thrift.test`; these definitions must stay in sync with it.

-record(goldentest_xtruct, {string_thing, byte_thing, i32_thing, i64_thing}).
-record(goldentest_xtruct2, {byte_thing, struct_thing, i32_thing}).
-record(goldentest_xception, {errorCode, message}).
-record(goldentest_xception2, {errorCode, struct_thing}).
