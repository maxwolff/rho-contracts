const { bn, mantissa, sendCall, logSend, hashEncode, cTokens } = require('./util/Helpers');


describe('InterestRateModel', () => {
	let model;

	const setup = async () => {
		const yOffset = bn(0.05e18);
		const slopeFactor = bn(0.5e36);
		const rateFactorSensitivity = bn(0.000075e18);
		const feeBase = bn(0.001e18);
		const feeSensitivity = bn(0.003e18);
		const range = bn(0.05e18);
		model = await deploy('InterestRateModel', [
			yOffset,
			slopeFactor,
			rateFactorSensitivity,
			feeBase,
			feeSensitivity,
			range
		]);
	};

	// TODO XXXs

	it('basic userReceiveFixed', async() => {
		await setup()
		const res = await call(model, 'getSwapRate', [0, false, bn(1000e18), bn(50e18), bn(100e18)]);
		expect(res.rateFactorNew).toEqNum(-7.5e14);
		expect(bn(res.rate)).toAlmostEqual(bn(5.2447e16));

		const res2 = await call(model, 'getSwapRate', [-7.5e14, true, bn(1000e18), bn(50e18), bn(100e18)]);
		expect(res2.rateFactorNew).toEqNum(0);
		expect(bn(res2.rate)).toAlmostEqual(bn(5.25e16));
	})
});
