# Performance reference

How the numbers are measured and what the existing measurements say.
All figures on this page are results of the checked-in benchmark
scripts run on previous revisions — reproducible on your hardware, not
re-measured for this document.

## Codec benchmark

The codec hot path is benchmarked against the vendored official Apache
Thrift 0.25.0 Erlang runtime with `scripts/bench` (erlperf, continuous
mode, average of three 500 ms samples ± sample stddev, single process;
knobs via `BENCH_WARMUP`, `BENCH_SAMPLES`, `BENCH_SAMPLE_MS`). The
benchmark is a hand-run script, not a test suite. Reference numbers
include a fresh membuffer transport and protocol per operation, which
its API requires; both sides run on the same ThriftTest payloads.

### Binary protocol

| case | operation | thrift_runtime | Apache Thrift 0.25.0 | speedup |
|------|-----------|-----------:|---------------------:|--------:|
| Xtruct (42 B)     | encode | 2.48 M/s | 466 K/s | 5.3x |
| Xtruct            | decode | 1.35 M/s | 227 K/s | 5.9x |
| Xtruct2 (51 B)    | encode | 1.53 M/s | 332 K/s | 4.6x |
| Xtruct2           | decode | 815 K/s  | 122 K/s | 6.7x |
| Insanity (3.2 KB) | encode | 38.6 K/s | 4.6 K/s | 8.3x |
| Insanity          | decode | 16.2 K/s | 2.6 K/s | 6.2x |

### Compact protocol

The same payload set on both sides — `thrift_runtime_compact` against
the vendored `thrift_compact_protocol` (28 B / 24 B / 1.2 KB on the
wire, roughly half the binary encoding):

| case | operation | thrift_runtime | Apache Thrift 0.25.0 | speedup |
|------|-----------|-----------:|---------------------:|--------:|
| Xtruct (28 B)      | encode | 1.54 M/s | 263 K/s | 5.9x |
| Xtruct             | decode | 1.11 M/s | 218 K/s | 5.1x |
| Xtruct2 (24 B)     | encode | 1.01 M/s | 209 K/s | 4.8x |
| Xtruct2            | decode | 664 K/s  | 132 K/s | 5.0x |
| Insanity (1.2 KB)  | encode | 12.6 K/s | 4.9 K/s | 2.6x |
| Insanity           | decode | 13.2 K/s | 2.4 K/s | 5.4x |

### JSON protocol

The same payload set on both sides — `thrift_runtime_json` against
the vendored `thrift_json_protocol` (87 B / 110 B / 6.7 KB on the
wire; decode is measured at message level, since the official JSON
reader primes on a whole message):

| case | operation | thrift_runtime | Apache Thrift 0.25.0 | speedup |
|------|-----------|-----------:|---------------------:|--------:|
| Xtruct (87 B)      | encode | 1.14 M/s | 113 K/s | 10.1x |
| Xtruct             | decode | 103 K/s  | 67 K/s  | 1.5x |
| Xtruct2 (110 B)    | encode | 1.01 M/s | 60 K/s  | 16.8x |
| Xtruct2            | decode | 51 K/s   | 46 K/s  | 1.1x |
| Insanity (6.7 KB)  | encode | 15.3 K/s | 1.2 K/s | 12.9x |
| Insanity           | decode | 1.2 K/s  | 1.1 K/s | 1.1x |

JSON encode is several times faster because the official side formats
every token through `io_lib`; on decode both sides scan the same text,
so the numbers sit ahead of parity (1.1–1.5× on these payloads).

The numbers above were measured on OTP 29; an OTP 28 run confirms the
same ratios. The same benchmark also reports a `facade (record repr) vs
reference` block for the binary protocol — the application-facing
`thrift_runtime:encode/2`/`decode/3` path over the record
representation, which engages the repr-native one-pass codecs — where
the decode rows run 7.9–11.5× the official runtime and the encode rows
3.1–7.0×. The specialized codecs also hold their own against the
generic interpreter inside this runtime — the same benchmark reports
specialized vs generic ratios of 0.9–1.5× across the protocol/struct
matrix (same-module and cross-module references call generated codecs
directly; public ref entries read the dispatch cache without a module
hop).

Only the speedup ratios on the same machine are meaningful; run
`./scripts/bench` to get numbers for your hardware.

## Why the codecs are fast

- **Specialized codecs on the hot path.** The emitter compiles a
  per-struct wire codec into every generated module, and named struct
  references dispatch straight into it — no descriptor interpretation
  at runtime. The emitter writes specialized per-struct wire codecs
  into `<mod>_types.erl` for all three protocols —
  `encode_<X>_wire`/`decode_<X>_wire`,
  `encode_<X>_compact`/`decode_<X>_compact` and
  `encode_<X>_json`/`decode_<X>_json`, each behind its
  `binary_codec/1`, `compact_codec/1` or `json_codec/1` index — and
  named struct references dispatch straight into them. RPC parameters
  and results get the same treatment: every generated function carries
  per-protocol `codecs` hooks in its `function_info`, so calls skip the
  descriptor engine even though params and results are synthetic inline
  structs. The generic engine remains for hand-written descriptors,
  custom protocol modules and as the equivalence reference the PropEr
  suite pins the specialized codecs to.
- **One-pass fast path.** Binary-protocol calls through the
  `thrift_runtime` facade take a one-pass path when the target module
  was generated with repr-native codecs (the default): `encode/2,3`
  reads a tuple-with-tag record, an atom- or binary-keyed map (or a
  native record, OTP 29+) straight to wire bytes, and `decode/3` builds
  the requested representation directly, with no intermediate wire map.
  Any value the fast path cannot represent — mixed nesting, malformed
  shapes — retries the two-pass path and answers identically, byte for
  byte and error for error; a PropEr property pins that parity on
  well-formed, corrupted and mixed inputs across all four
  representations.
- **Compiled descriptors.** The codec compiles type descriptors once —
  referenced structs in a shared `persistent_term` cache, inline
  descriptors in a per-process memo — so nested schemas are never
  re-resolved per wire occurrence. Record-mode structs additionally
  generate direct representation converters in `<mod>_types_repr.erl`
  (literal field atoms, no descriptor walk); the converters live
  outside the types module on purpose — generated-code layout is a
  measured performance variable.

## Regression benchmarks

`scripts/bench-regression` compares the current checkout with a real
git ref (`v0.8.0` by default, override with `BENCH_REGRESSION_REF`).
It generates both versions, checks byte equality and round-trips, then
alternates paired measurements in one VM. Both sides use the same
function atoms in distinct modules. Same-module and cross-module
direct rows isolate emitted code and form the regression gate. Public
rows expose dispatch costs for diagnosis and remain `gate=false`
because their top-level module/cache keys differ. Direct targets are
external funs created before timing, not dynamic module lookups per
iteration.

Each row reports the median current/baseline throughput ratio and a
bootstrap 95% interval. A gated row passes only when both its median
and the interval's lower bound meet 0.99; confirmed regressions and
inconclusive rows both make the script fail. Use `THRIFT_BENCH_ROUNDS`,
`THRIFT_BENCH_SAMPLE_MS`, `THRIFT_BENCH_THRESHOLD`,
`THRIFT_BENCH_PROTOCOL`, and `THRIFT_BENCH_ENTRY` to control the run.
The defaults are 31 rounds and 250 ms per side; shorter runs are for
smoke checks, not a 1% gate. An interval that crosses the configured
threshold is inconclusive: increase the sample count or duration
before claiming parity at that precision.

`scripts/bench-rpc` measures the RPC path end to end: a generated
`ThriftTest` server and client on a 127.0.0.1 loopback (framed
transport, binary protocol), historical ref against the current
checkout, paired rounds with the same 0.99 gate. `THRIFT_BENCH_FUNCTION`
selects one function. It is the acceptance check for RPC-path
optimizations, which codec-level numbers alone cannot prove.
