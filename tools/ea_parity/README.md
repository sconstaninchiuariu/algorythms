# EA parity harness

Differential test of `LiquidityAlgo.mq5` against an independent reference of the
Pine strategy decisions (`pine_ref.py`), on synthetic M1 data.

    ./build.sh                       # C++ build of the EA on a mock MT5 (sanitizers on)
    ./runsim 3 data3.csv > ea3.txt   # run seed 3, dump the M1 data
    python3 pine_ref.py data3.csv > ref3.txt
    # compare the ARM / MSS / ENTRY / EXIT / LIQ / CHANCE streams after a settle period

What it checks: syntax/type errors, crashes or out-of-range access, and that the
EA's zone engine, level consumption, CE engine, second chance and entries produce
the same decisions as the reference. What it cannot check: TradingView's own
`request.security` timing, broker fills/spread, real MT5 compile or tester data.
`reference` and EA share the author's reading of the Pine code, so a wrong
assumption would be in both; compare real runs with the `LogParity` events.
