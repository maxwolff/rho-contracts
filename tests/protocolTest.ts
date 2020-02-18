const { bn, futureTime, prep, sendCall } = require("./util/Helpers");

const deploy = async () => {
	console.log("1");
	const mockCToken = await deploy("MockCToken", ["5"]);
	console.log("1");
	const model = await deploy("InterestRateModel", []);
	console.log("1");
	const underlying = await deploy("FaucetToken", [
		"0",
		"token1",
		"18",
		"TK1"
	]);
	const rho = await deploy("Rho", [
		model.address,
		mockCToken.address,
		underlying.address
	]);

	return {
		mockCToken,
		model,
		underlying,
		rho
	};
};

describe("Add liquidity", () => {
	let mockCToken, model, underlying, rho;
	const lp = accounts[1];
	const supplyAmount = bn(1e18);

	beforeEach(async () => {
		({ mockCToken, model, underlying, rho } = await deploy());
		await prep(rho._address, supplyAmount, underlying, lp);
		await send(rho.methods.supplyLiquidity(supplyAmount));
	});

	it("should pull tokens", async () => {
		const bal1 = await call(underlying.methods.balanceOf(lp));
		expect(bal1).toEqual(0);
	});
});
