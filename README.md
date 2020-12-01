# Rho

An AMM interest rate swap protocol [spec](https://docs.google.com/document/d/1GwLj1i7xsREvoT-wZBJ3JKPPi7KUkr-bWvobaZMA2Lc/edit?usp=sharing).
* Uses CTokens as collateral, and for interest rates.
* Capped downside for user, theoretically uncapped upside.


Run tests:
* install `solc` version ^0.6.10
* `yarn`
* `yarn test`

Run fork test:
* node script/infuraProxy.js
* script/forkChain
* script/forkTest

Deploy locally (saddle only compatible w node 13):
* `script/chain`
* `script/deploy development`

Deploy elsewhere: 
* `script/deploy development`
or 
* `yarn console -n kovan` via saddle console
* `.deploy RhoLensV1 0x123`
* `await rhoLensV1.methods.rho().call();`
* `await rho.methods.supplierLiquidity().call();`
* `await rho.methods._pause(true).send();`

Resources:
* [Spreadsheet](https://docs.google.com/spreadsheets/d/1w2EEdeKWvx7haG0p8vp5h9kBmOGBXVOpb6UTZOOV1io/edit#gid=27052314)
* [Model](https://observablehq.com/d/d04daaa430a6de46)
* [spec](https://docs.google.com/document/d/1GwLj1i7xsREvoT-wZBJ3JKPPi7KUkr-bWvobaZMA2Lc/edit?usp=sharing) (missing cToken as collateral details)

Tests TODO:
* Integration fork test: show exchange rate of collateral changing behaves correctly. Multiple concurrent swaps
* Better nterest rate model test
* Supply multiple times, show update works (accrues interest, idx updates)
* Test more variations of userPayFixed / receiveFixed swaps making & losing money
