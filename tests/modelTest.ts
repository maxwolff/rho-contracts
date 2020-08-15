const { bn } = require('./util/Helpers');


const yOffset = bn(2.5e10);
const slopeFactor = bn(0.5e36);
const range = bn(2.5e10);

const rateFactorSensitivity = bn(7.5e13);
const feeBase = bn(5e9);
const feeSensitivity = bn(3e9);

const modelParams = [
	yOffset,
	slopeFactor,
	rateFactorSensitivity,
	feeBase,
	feeSensitivity,
	range
];

describe('InterestRateModel', () => {
	let model;

	beforeAll(async () => {
		model = await deploy('InterestRateModel', modelParams);
	});

	const runTest = async(args, expectedRate, expectedRateFactorNew) => {
		const {rateFactorNew, rate} = await call(model, 'getSwapRate', args);
		expect(rateFactorNew).toEqNum(expectedRateFactorNew);
		expect(rate).toAlmostEqual(expectedRate);
	}


	/* all rates are per block. using blocksPerYear= 2102400, 1e10 per block is ~2.1% (1e18 mantissa)
	 * [rateFactorPrev, userPayingFixed, orderNotional, lockedCollateral, supplierLiquidity], [rate, rateFactorNew]
	*/

	it('userPayFixed from 0', async() => {
		return await runTest([0, true, bn(1e20), bn(5e18), bn(10e18)], bn(31526516489), bn(7.5e14));
	});

	it('userReceiveFixed from 0', async() => {
		return await runTest([0, false, bn(1e20), bn(5e18), bn(10e18)], bn(18473483511), bn(-7.5e14));
	});

	it('userPayFixed from 0.5e18', async() => {
		return await runTest([bn(0.5e18), true, bn(1e20), bn(5e18), bn(10e18)], bn(45948179665), bn(0.50075e18));
	});

	it('userReceiveFixed from 0.5e18', async() => {
		return await runTest([bn(0.5e18), false, bn(1e20), bn(5e18), bn(10e18)], bn(32919312144), bn(0.49925e18));
	});

	it('userPayFixed from -.5e18', async() => {
		return await runTest([bn(-0.5e18), true, bn(1e20), bn(5e18), bn(10e18)], bn(17080687856), bn(-0.49925e18));
	});

	it('userReceiveFixed from -.5e18', async() => {
		return await runTest([bn(-0.5e18), false, bn(1e20), bn(5e18), bn(10e18)], bn(4051820335), bn(-0.50075e18));
	});

	it('rate floored at 0', async() => {
		// rate is floored at 0, rf doesnt change if 0
		return await runTest([bn(-5e18), false, bn(1e20), bn(5e18), bn(10e18)], bn(0), bn(-5e18));
	});
});

module.exports = {
	modelParams
}

