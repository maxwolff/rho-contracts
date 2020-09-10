# Rho

An AMM interest rate swap protocol [spec](https://docs.google.com/document/d/1GwLj1i7xsREvoT-wZBJ3JKPPi7KUkr-bWvobaZMA2Lc/edit?usp=sharing).
Uses CTokens as collateral. Interest rates can be benchmarked on either the collateral CToken, another CToken, or any contract with a `borrowIndex`.

Run tests:
* install `solc` version ^0.6.10
* `yarn`
* `yarn test`

Deploy locally:
* `script/chain`
* `script/deploy development`

Resources:
* [Spreadsheet](https://docs.google.com/spreadsheets/d/1w2EEdeKWvx7haG0p8vp5h9kBmOGBXVOpb6UTZOOV1io/edit#gid=27052314)
* [Model](https://observablehq.com/d/d04daaa430a6de46)
* [spec](https://docs.google.com/document/d/1GwLj1i7xsREvoT-wZBJ3JKPPi7KUkr-bWvobaZMA2Lc/edit?usp=sharing) (missing cToken as collateral details)

Tests TODO:
* Integration fork test: show exchange rate of collateral changing behaves correctly. Multiple concurrent swaps
* Better nterest rate model test
* Supply multiple times, show update works (accrues interest, idx updates)
* Test more variations of userPayFixed / receiveFixed swaps making & losing money
