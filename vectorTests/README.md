# Vector processing tests

Run from the repository root on CAEN Linux:

```sh
make vector_test       # vector_unit module tests
make vector_decode_test # shared scalar/vector decoder and ID-stage tests
make vector_tests      # both vector module testbenches
make vector_programs   # all rvv_*.s here, checked on the CPU
make verify            # include caches and CPU integration tests
```

`vector_test.sv` tests the vector engine with controls from the shared decoder.
`vector_decode_test.sv` checks all 19 encodings, scalar operand dependencies,
forwarding, and two-wide ID issue rules. `rvv_*.s` programs exercise the engine
through the complete processor, including adjacent producer/consumer chains.
`vector_program_regression.py --prepare-only` creates independent reference
images/traces for the Makefile's VCS program checker. Its optional portable mode
uses Verilator.

See [CAEN_TESTS.md](../CAEN_TESTS.md) for target details and
[the program inventory](../programs/README_RVV.md) for coverage and expected
outputs. Scalar instructions in the programs provide setup/observation only.
The current vector unit serializes whole instructions; dependent chains test
readiness and stalls rather than an existing vector bypass network.
