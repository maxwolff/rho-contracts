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

	const rhoArgs = [
		modelAddr, 
		cTokenAddr,
		compAddr,
		conf.minFloatMantissaPerBlock,
		conf.maxFloatMantissaPerBlock,
		conf.swapMinDuration,
		conf.supplyMinDuration,
		conf.admin,
		conf.liquidityLimit
	];
	const rho = await deploy('Rho', rhoArgs);
	
	console.log("rho args: ", rhoArgs);

	const rhoLensAddr = conf.rhoLens || (await deploy('RhoLensV1', [rho._address]))._address;

	if (network == 'development') {
		await send(cToken, 'allocateTo', [conf.admin, str(500e10)]);
		await send(cToken, 'approve', [rho._address, str(500e10)], { from: conf.admin });
		await send(cToken, 'setAccrualBlockNumber', [0]);
	}

	return {'cToken': cTokenAddr, comp: compAddr, 'rho': rho._address, model: modelAddr, rhoLens: rhoLensAddr};
};

const getConf = () => {
	const mainnet = {
		//IRM
		yOffset: str(1.9e10),
		slopeFactor: str(0.5e36),
		rateFactorSensitivity: str(1e15),
		feeBase: str(1e9),
		feeSensitivity: str(1.5e9),
		range: str(2.5e10),

		minFloatMantissaPerBlock: str(0),
		maxFloatMantissaPerBlock: str(1e11),
		liquidityLimit: str(1e12), // 10k ctokens
		supplyMinDuration: str(5), // enough to prevent hijinks, too few to little for users to notice
		swapMinDuration: str(45500), // 7 days in blocks
		comp: "0xc00e94cb662c3520282e6f5717214004a7f26888", // mainnet comp
		cToken: "0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643",// mainnet cdai
		admin: "0x74dacD80d9B67912Cb957966465cCc81e62ccc4f",// mainnet admin
		model: "0xc0D7e5fd51762E6A36aF925534C53EafD2789562"
	};

	return {
		mainnet,
		development: {
			...mainnet,
			swapMinDuration: str(10),
			initExchangeRate: str(2e8),
			borrowRateMantissa: str(1e10),
			comp: null,
			cToken: null, 
			admin: saddle.accounts[0]
		},
		kovan: {
			...mainnet,
			supplyMinDuration: str(5),
			swapMinDuration: str(10),
			liquidityLimit: str(1e10), // 100 ctokens
			comp: "0x61460874a7196d6a22d1ee4922473664b3e95270",
			cToken: "0xf0d0eb522cfa50b716b3b1604c4f0fa6f04376ad",
			admin: "0xc5Ea8C731aA7dB66Ffa91532Ee48f68419B49b48",
		}
	}
}

const main = async () => {
	const conf = getConf();
	const network = saddle.network_config.network;
	assert(Object.keys(conf).includes(network), "Unsupported network");
	const networkJson = await deployProtocol(conf[network], network);
	console.log(networkJson)
	await writeNetworkFile(network, networkJson, 'networks');
	await writeNetworkFile(network, {"RhoLensV1": networkJson.rhoLens, "Rho": networkJson.rho}, '.build');
};


(async () => {
	await main();
})();
