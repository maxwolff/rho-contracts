const fs = require('fs');
const path = require('path');
const util = require('util');
const assert = require('assert');
const { str, sendRPC } = require('../tests/util/Helpers.ts');

const writeNetworkFile = async (network, value) => {
    const networkFile = path.join('networks', `${network}.json`);
	await util.promisify(fs.writeFile)(networkFile, JSON.stringify(value, null, 4));
 };

const getCloseArgs = (openTx) => {
	const vals = openTx.events.OpenSwap.returnValues;
	return [vals.userPayingFixed, vals.benchmarkIndexInit, vals.initBlock, vals.swapFixedRateMantissa, vals.notionalAmount, vals.userCollateralCTokens, vals.owner];
}

const deployProtocol = async (conf, network) => {
	const a1 = conf.admin || saddle.accounts[0];

	let cToken;
	let cTokenAddr;
	if (network == 'development') {
		cToken = await deploy('MockCToken', [conf.initExchangeRate, conf.borrowRateMantissa, '0', 'token2', '18', 'Collateral Token']);
		cTokenAddr = cToken._address;
	} else {
		cTokenAddr = conf.cToken;
	}
	const compAddr = conf.comp || (await deploy('FaucetToken', ['0', 'COMP', '18', 'Compound Governance Token']))._address;
	const model = await deploy('InterestRateModel', [
		conf.yOffset,
		conf.slopeFactor,
		conf.rateFactorSensitivity,
		conf.feeBase,
		conf.feeSensitivity,
		conf.range
	]);
	const rho = await deploy('Rho', [
		"0xEBc0D4Ab4C3b95B3Ee4C84d30922E5EDC0c4BeA5", // model._address, 
		cTokenAddr,
		compAddr,
		conf.minFloatMantissaPerBlock,
		conf.maxFloatMantissaPerBlock,
		conf.swapMinDuration,
		conf.supplyMinDuration,
		a1
	]);

	const rhoLens = await deploy('RhoLensV1', [rho._address]);

	if (network == 'development') {
		await send(cToken, 'allocateTo', [a1, str(500e10)]);
		await send(cToken, 'approve', [rho._address, str(500e10)], { from: a1 });
		await send(cToken, 'setAccrualBlockNumber', [0]);
		await send(rho, 'supply', [str(50e10)], {from: a1});
		await send(rho, 'openPayFixedSwap', [str(1e18), 4e10]);
		// await sendRPC('evm_mineBlockNumber', [345600 + 100], saddle);
		// const args = getCloseArgs(openTx);
		// const tx = await send(rho, 'close', args);

		// console.log("open", openTx.events.OpenSwap)
		// console.log("close", tx.events.CloseSwap)
	}

	return {'cToken': cTokenAddr, 'comp': compAddr, 'model': "0xEBc0D4Ab4C3b95B3Ee4C84d30922E5EDC0c4BeA5" /*model._address*/, 'rho': rho._address, 'rhoLens': rhoLens._address};
};


(async () => {
	const base = {
		yOffset: str(2.5e10),
		slopeFactor: str(0.5e36),
		range: str(2.5e10),
		rateFactorSensitivity: str(1e15),
		feeBase: str(5e9),
		feeSensitivity: str(3e9),

		minFloatMantissaPerBlock: str(0),
		maxFloatMantissaPerBlock: str(1e11),
	};

	const conf = {
		mainnet: {
			...base,
			swapMinDuration: str(345600), // 60 days in blocks
			supplyMinDuration: str(172800), // 60 days in blocks
			comp: "0xc00e94cb662c3520282e6f5717214004a7f26888",
			cToken: "0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643"// cdai

		},
		development: {
			...base,
			initExchangeRate: str(2e8),
			borrowRateMantissa: str(1e10),
			comp: null,
			cToken: null
		},
		kovan: {
			...base,
			supplyMinDuration: str(5),
			swapMinDuration: str(10),
			comp: "0x61460874a7196d6a22d1ee4922473664b3e95270",
			cToken: "0xf0d0eb522cfa50b716b3b1604c4f0fa6f04376ad",
			admin: "0xc5Ea8C731aA7dB66Ffa91532Ee48f68419B49b48"
		},
		// mainnet
	}

	const network = saddle.network_config.network;
	assert(Object.keys(conf).includes(network), "Unsupported network");
	console.log(conf[network])
	const networkJson = await deployProtocol(conf[network], network);
	console.log(networkJson)
	await writeNetworkFile(network, networkJson);
})();
