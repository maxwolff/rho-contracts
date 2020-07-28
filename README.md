# Rho

An AMM interest rate swap protocol [spec](https://docs.google.com/document/d/1GwLj1i7xsREvoT-wZBJ3JKPPi7KUkr-bWvobaZMA2Lc/edit?usp=sharing).
Uses CTokens as collateral. Interest rates can be benchmarked on either the collateral CToken, another CToken, or any contract with a `borrowIndex`.

Run tests:
* `yarn`
* `yarn test`

Deploy locally:
* `PROVIDER="http://localhost:8545/" npx saddle -n development script deploy`

Notes:
* Spec doesnt have cToken as collateral yet
* Consider making `cTokenCollateral` & `Benchmark`

Tests TODO:
* Integration fork test: show exchange rate of collateral changing behaves correctly. Multiple concurrent swaps
* Interest rate model test
* Supply multiple times, show update works (accrues interest, idx updates)
* Test more variations of userPayFixed / receiveFixed swaps making & losing money
