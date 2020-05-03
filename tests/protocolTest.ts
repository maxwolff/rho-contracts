const { bn, mantissa, prep, sendCall } = require('./util/Helpers');

const deployProtocol = async (opts = {}) => {
	const mockCToken = opts.benchmark || await deploy('MockCToken', []);
	const model = await deploy('InterestRateModel', []);
	const underlying = await deploy('FaucetToken', [
		'0',
		'token1',
		'18',
		'TK1',
	]);
	const rho = await deploy('MockRho', [
		model._address,
		mockCToken._address,
		underlying._address,
	]);

	return {
		mockCToken,
		model,
		underlying,
		rho,
	};
};

describe('Rho Unit Tests', () => {
	describe('Constructor', () => {
		it('does not work with unset benchmark', async () => {
			const bad = await deploy('BadBenchmark', []);
			await expect(deployProtocol({benchmark: bad})).rejects.toRevert("Unset benchmark index");
		});
	});

	describe("Add liquidity", () => {
		let mockCToken, model, underlying, rho;
		const lp = accounts[1];
		const supplyAmount = mantissa(1);
		const block = 10;
		const benchmarkIndexInit = mantissa(1.5);

		beforeAll(async() => {
			({ mockCToken, model, underlying, rho } = await deployProtocol());
			await prep(rho._address, supplyAmount, underlying, lp);
			await send(rho, "setBlockNumber", [block]);
			await send(mockCToken, "setBorrowIndex", [benchmarkIndexInit]);
			await send(rho, "supplyLiquidity", [supplyAmount], { from: lp});
		})

		it("should pull tokens", async () => {
			const lpBalance = await call(underlying, "balanceOf", [lp]);
			expect(0).toEqualNumber(lpBalance);

			const protocolBalance = await call(underlying, "balanceOf", [rho._address]);
			expect(supplyAmount).toEqualNumber(protocolBalance);
		});

		it("should update account struct", async () => {
			const acct = await call(rho, "accounts", [lp]);
			expect(acct.amount).toEqualNumber(supplyAmount);
			expect(acct.supplyBlock).toEqualNumber(block);
			expect(acct.supplyIndex).toEqualNumber(mantissa(1));
		});

		it("should update globals", async() => {
			expect(supplyAmount).toEqualNumber(await call(rho, "totalLiquidity", []));
			expect(benchmarkIndexInit).toEqualNumber(await call(rho, "benchmarkIndexStored", []));
		})

		it.todo("if second time, trues up");
	});

	describe("Accrue Interest", () => {
		let mockCToken, model, underlying, rho;
		const lp = accounts[1];
		const supplyAmount = mantissa(1);
		const block = 10;
		const benchmarkIndexAfter= mantissa(1.6);

		beforeAll(async() => {
			({ mockCToken, model, underlying, rho } = await deployProtocol());
			await prep(rho._address, supplyAmount, underlying, lp);
			await send(rho, "setBlockNumber", [block]);
			await send(mockCToken, "setBorrowIndex", [benchmarkIndexAfter]);
			await send(rho, "supplyLiquidity", [supplyAmount], { from: lp});
		})

		// Basic unit tests

		// it.todo("should mock receive fixed", async () => {

		// });
		//supply idx increment, fixedToReceive decrement
		// locked collateral decrease
		it.todo("should mock pay fixed");

		it.todo("should mock pay float");

		it.todo("should mock receive float");
		// supply idx increment, fixedToReceive decrement, floatRateCreditPrincipal decrement
		// floatRateDebtBlocks decrement
		// locked collateral decrease

		it("should update benchmark index", async () => {
			await send(rho, "harnessAccrueInterest", []);
			expect(benchmarkIndexAfter).toEqualNumber(await call(rho, "benchmarkIndexStored", []));
		})

	});

	describe('supply idx', () => {
		it.todo('prove supply idx works');
	});
});
