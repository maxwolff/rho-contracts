# Rho

An AMM interest rate swap protocol deployed at Rho is deployed on mainnet at: [0xEC41a154386fe49aFa1339C5419eCB8f19a61294](https://etherscan.io/address/0xEC41a154386fe49aFa1339C5419eCB8f19a61294)
* Uses CTokens as collateral, and for interest rates.
* Capped downside for user, theoretically uncapped upside.


Run tests:
* install `solc` version ^0.6.10
* `yarn`
* `yarn test`

Run fork test:
* `node script/infuraProxy.js`
* `script/forkChain`
* `script/forkTest`

Deploy locally (use node 12 or 13):
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
* [Docs](https://github.com/Rho-protocol/rho-docs)
