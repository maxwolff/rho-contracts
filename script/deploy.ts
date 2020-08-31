const fs = require('fs');
const path = require('path');
const util = require('util');
const assert = require('assert');
const exec = util.promisify(require('child_process').exec);

const { str } = require('../tests/util/Helpers.ts');

const writeNetworkFile = async (network, value) => {
    const networkFile = path.join('networks', `${network}.json`);
	await util.promisify(fs.writeFile)(networkFile, JSON.stringify(value, null, 4));
 };

const deployProtocol = async (conf) => {
	const cToken = conf.cToken || (await deploy('MockCToken', [conf.initExchangeRate, conf.borrowRateMantissa, '0', 'token2', '18', 'Collateral Token']))._address;
	const comp = conf.comp || (await deploy('FaucetToken', ['0', 'COMP', '18', 'Compound Governance Token']))._address;
	const model = (await deploy('InterestRateModel', [
		conf.yOffset,
		conf.slopeFactor,
		conf.rateFactorSensitivity,
		conf.feeBase,
		conf.feeSensitivity,
		conf.range
	]))._address;
	const rho = (await deploy('Rho', [
		model,
		cToken,
		comp,
		conf.minFloatMantissaPerBlock,
		conf.maxFloatMantissaPerBlock,
		conf.swapMinDuration,
		conf.supplyMinDuration,
		saddle.accounts[0]
	]))._address;

	return {cToken, comp, model, rho};
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
	const networkJson = await deployProtocol(conf[network]);
	await writeNetworkFile(network, networkJson);
})();
