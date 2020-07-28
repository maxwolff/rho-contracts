const { bn } = require('../tests/util/Helpers.ts');

const MIN_FLOAT_MANTISSA_PER_BLOCK = bn(0);
const MAX_FLOAT_MANTISSA_PER_BLOCK = bn(1e11); // => 2.1024E17 per year via 2102400 blocks / year. ~21%, 3.5% (3.456E16) per 60 days (345600 blocks)
const INIT_EXCHANGE_RATE = bn(2e8);
const SWAP_MIN_DURATION = bn(345600);// 60 days in blocks, assuming 15s blocks
const SUPPLY_MIN_DURATION = bn(172800);

const yOffset = bn(0.05e18);
const slopeFactor = bn(0.5e36);
const rateFactorSensitivity = bn(0.000075e18);
const feeBase = bn(0.001e18);
const feeSensitivity = bn(0.003e18);
const range = bn(0.1e18);


/* PROVIDER="http://localhost:8545/" npx saddle -n development script deploy */

// **** LOCAL TEST DEPLOY **** //

const deployProtocol = async (opts = {}) => {
	const mockCToken = opts.benchmark || (await deploy('MockCToken', [INIT_EXCHANGE_RATE, '0', 'token1', '18', 'Benchmark Token']));
	const cTokenCollateral = opts.collat || (await deploy('MockCToken', [INIT_EXCHANGE_RATE, '0', 'token2', '18', 'Collateral Token']));
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
		mockCToken._address,
		cTokenCollateral._address,
		MIN_FLOAT_MANTISSA_PER_BLOCK,
		MAX_FLOAT_MANTISSA_PER_BLOCK,
		SWAP_MIN_DURATION,
		SUPPLY_MIN_DURATION
	]);
};

(async () => {
	await deployProtocol();
})();
