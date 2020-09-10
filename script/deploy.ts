const fs = require('fs');
const path = require('path');
const util = require('util');
const assert = require('assert');
const { str, sendRPC } = require('../tests/util/Helpers.ts');

const writeNetworkFile = async (network, value) => {
    const networkFile = path.join('networks', `${network}.json`);
	await util.promisify(fs.writeFile)(networkFile, JSON.stringify(value, null, 4));
 };

const deployProtocol = async (conf, network) => {
	const a1 = saddle.accounts[0];

	if (network == 'development') {
		await sendRPC('evm_mineBlockNumber', [100], saddle);
		console.log(await sendRPC('eth_blockNumber', [], saddle));

	}
	let cToken;
	if (conf.cToken) {
		cToken = conf.cToken;
	} else {
		cToken = await deploy('MockCToken', [conf.initExchangeRate, conf.borrowRateMantissa, '0', 'token2', '18', 'Collateral Token']);
	}
	const comp = conf.comp || await deploy('FaucetToken', ['0', 'COMP', '18', 'Compound Governance Token']);
	const model = await deploy('InterestRateModel', [
		conf.yOffset,
		conf.slopeFactor,
		conf.rateFactorSensitivity,
		conf.feeBase,
		conf.feeSensitivity,
		conf.range
	]);
	const rho = await deploy('Rho', [
		model._address,
		cToken._address,
		comp._address,
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
		console.log(await send(rho, 'supply', [str(50e10)], {from: a1}));
	}

	return {'cToken': cToken._address, 'comp': comp._address, 'model': model._address, 'rho': rho._address, 'rhoLens': rhoLens._address};
};


(async () => {
	const mainnet = {
		yOffset: str(2.5e10),
		slopeFactor: str(0.5e36),
		range: str(2.5e10),
		rateFactorSensitivity: str(7.5e13),
		feeBase: str(5e9),
		feeSensitivity: str(3e9),

		minFloatMantissaPerBlock: str(0),
		maxFloatMantissaPerBlock: str(1e11),
		initExchangeRate: str(2e8),
		swapMinDuration: str(345600), // 60 days in blocks
		supplyMinDuration: str(172800), // 60 days in blocks
		comp: "0xc00e94cb662c3520282e6f5717214004a7f26888",
		cToken: "0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643"// cdai
	};

	const conf = {
		development: {
			...mainnet,
			initExchangeRate: str(2e8),
			borrowRateMantissa: str(1e10),
			comp: null,
			cToken: null
		},
		// kovan: {
			// ...mainnet,
			// comp: "0x",
			// benchmark: "0x"
			// cTokenCollateral: "0x"
		// },
		// mainnet
	}

	const network = saddle.network_config.network;
	assert(Object.keys(conf).includes(network), "Unsupported network");
	const networkJson = await deployProtocol(conf[network], network);
	await writeNetworkFile(network, networkJson);
})();
