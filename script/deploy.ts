const { bn } = require('../tests/util/Helpers.ts');

const MIN_FLOAT_MANTISSA_PER_BLOCK = bn(0);
const MAX_FLOAT_MANTISSA_PER_BLOCK = bn(1e11); // => 2.1024E17 per year via 2102400 blocks / year. ~21%, 3.5% (3.456E16) per 60 days (345600 blocks)
const INIT_EXCHANGE_RATE = bn(2e8);
const SWAP_MIN_DURATION = bn(345600);// 60 days in blocks, assuming 15s blocks
const SUPPLY_MIN_DURATION = bn(172800);

const yOffset = bn(2.5e10);
const slopeFactor = bn(0.5e36);
const range = bn(2.5e10);

const rateFactorSensitivity = bn(7.5e13);
const feeBase = bn(5e9);
const feeSensitivity = bn(3e9);


/* PROVIDER="http://localhost:8545/" npx saddle -n development script deploy */

// **** LOCAL TEST DEPLOY **** //

const deployProtocol = async (opts = {}) => {
	const benchmark = opts.benchmark || (await deploy('MockCToken', [INIT_EXCHANGE_RATE, '0', 'token1', '18', 'Benchmark Token']));
	const cTokenCollateral = opts.collat || (await deploy('MockCToken', [INIT_EXCHANGE_RATE, '0', 'token2', '18', 'Collateral Token']));
	const comp = await deploy('FaucetToken', ['0', 'COMP', '18', 'Compound Governance Token']);

	const model = await deploy('InterestRateModel', [
		yOffset,
		slopeFactor,
		rateFactorSensitivity,
		feeBase,
		feeSensitivity,
		range
	]);
	const rho = await deploy('Rho', [
		model._address,
		benchmark._address,
		cTokenCollateral._address,
		comp._address,
		MIN_FLOAT_MANTISSA_PER_BLOCK,
		MAX_FLOAT_MANTISSA_PER_BLOCK,
		SWAP_MIN_DURATION,
		SUPPLY_MIN_DURATION,
		saddle.accounts[0]
	]);

	console.log({rho: rho._address, model: model._address, comp: comp._address})
};

(async () => {
	await deployProtocol();
})();
