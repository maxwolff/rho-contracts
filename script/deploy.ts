const fs = require('fs');
const path = require('path');
const util = require('util');
const assert = require('assert');
const { str, MAX_UINT } = require('../tests/util/Helpers.ts');

const writeNetworkFile = async (network, value, dir) => {
    const networkFile = path.join(dir, `${network}.json`);
	await util.promisify(fs.writeFile)(networkFile, JSON.stringify(value, null, 4));
};

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
	const modelAddr = conf.model || (await deploy('InterestRateModel', [
		conf.yOffset,
		conf.slopeFactor,
		conf.rateFactorSensitivity,
		conf.feeBase,
		conf.feeSensitivity,
		conf.range
	]))._address;
	const rho = await deploy('Rho', [
		modelAddr, 
		cTokenAddr,
		compAddr,
		conf.minFloatMantissaPerBlock,
		conf.maxFloatMantissaPerBlock,
		conf.swapMinDuration,
		conf.supplyMinDuration,
		a1,
		conf.liquidityLimit
	]);

	const rhoLensAddr = conf.rhoLens || (await deploy('RhoLensV1', [rho._address]))._address;

	if (network == 'development') {
		await send(cToken, 'allocateTo', [a1, str(500e10)]);
		await send(cToken, 'approve', [rho._address, str(500e10)], { from: a1 });
		await send(cToken, 'setAccrualBlockNumber', [0]);
	}

	return {'cToken': cTokenAddr, comp: compAddr, 'rho': rho._address, model: modelAddr, rhoLens: rhoLensAddr};
};

const main = async () => {
	const base = {
		yOffset: str(2.5e10),
		slopeFactor: str(0.5e36),
		range: str(2.5e10),
		rateFactorSensitivity: str(1e15),
		feeBase: str(2e9),
		feeSensitivity: str(2e9),

		minFloatMantissaPerBlock: str(0),
		maxFloatMantissaPerBlock: str(1e11),
		liquidityLimit: str(1e12)//MAX_UINT
	};
	const conf = {
		mainnet: {
			...base,
			swapMinDuration: str(345600), // 60 days in blocks
			supplyMinDuration: str(172800), // 60 days in blocks
			comp: "0xc00e94cb662c3520282e6f5717214004a7f26888",
			cToken: "0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643",// cdai
		},
		development: {
			...base,
			swapMinDuration: str(10),
			supplyMinDuration: str(5),
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
			admin: "0xc5Ea8C731aA7dB66Ffa91532Ee48f68419B49b48",
			
			model: "0x822a9EB2322097399Deea71163515e84a3BDd2c4"
		}
	}

	const network = saddle.network_config.network;
	assert(Object.keys(conf).includes(network), "Unsupported network");
	console.log(conf[network])
	const networkJson = await deployProtocol(conf[network], network);
	console.log(networkJson)
	await writeNetworkFile(network, networkJson, 'networks');
	await writeNetworkFile(network, {"RhoLensV1": networkJson.rhoLens, "Rho": networkJson.rho}, '.build');
};


(async () => {
	await main();
})();
