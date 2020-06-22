const { bn, mantissa, prep, sendCall, logSend } = require('./util/Helpers');

const MIN_FLOAT_MANTISSA_PER_BLOCK = bn(0);
const MAX_FLOAT_MANTISSA_PER_BLOCK = bn(1e11); // => 2.1024E17 per year via 2102400 blocks / year. ~21%, 3.5% (3.456E16) per 60 days (345600 blocks)

const deployProtocol = async (opts = {}) => {
	const mockCToken = opts.benchmark || (await deploy('MockCToken', []));
	const model = await deploy('MockInterestRateModel', []);
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
		MIN_FLOAT_MANTISSA_PER_BLOCK,
		MAX_FLOAT_MANTISSA_PER_BLOCK,
	]);
	return {
		mockCToken,
		model,
		underlying,
		rho,
	};
};

describe('Constructor', () => {
	it('does not work with unset benchmark', async () => {
		const bad = await deploy('BadBenchmark', []);
		await expect(deployProtocol({ benchmark: bad })).rejects.toRevert(
			'Benchmark index is zero'
		);
	});
});

describe('Protocol Unit Tests', () => {
	const [root, lp, a1, a2, ...accounts] = saddle.accounts;
	let mockCToken, model, underlying, rho;
	const supplyAmount = mantissa(1);
	const block = 100;
	const benchmarkIndexInit = mantissa(1.2);

	beforeEach(async () => {
		({ mockCToken, model, underlying, rho } = await deployProtocol());
		await prep(rho._address, supplyAmount, underlying, lp);
		await send(rho, 'setBlockNumber', [block]);
		await send(mockCToken, 'setBorrowIndex', [benchmarkIndexInit]);
		await send(rho, 'supplyLiquidity', [supplyAmount], {
			from: lp,
		});
	});

	describe('Add liquidity', () => {
		it('should pull tokens', async () => {
			const lpBalance = await call(underlying, 'balanceOf', [lp]);
			expect(0).toEqNum(lpBalance);

			const protocolBalance = await call(underlying, 'balanceOf', [
				rho._address,
			]);
			expect(supplyAmount).toEqNum(protocolBalance);
		});

		it('should update account struct', async () => {
			const acct = await call(rho, 'accounts', [lp]);
			expect(acct.amount).toEqNum(supplyAmount);
			expect(acct.supplyBlock).toEqNum(block);
			expect(acct.supplyIndex).toEqNum(mantissa(1));
		});

		it('should update globals', async () => {
			expect(supplyAmount).toEqNum(await call(rho, 'totalLiquidity', []));
			expect(benchmarkIndexInit).toEqNum(
				await call(rho, 'benchmarkIndexStored', [])
			);
		});

		it.todo('if second time, trues up');
	});

	describe('Accrue Interest', () => {
		it('should revert if index decreases', async () => {
			const delta = 10;
			await send(rho, 'setBlockNumber', [block + delta]);
			await send(mockCToken, 'setBorrowIndex', [mantissa(0.9)]);
			await expect(
				send(rho, 'harnessAccrueInterest', [])
			).rejects.toRevert('Decreasing float rate');
		});

		it('should update benchmark index', async () => {
			let newIdx = mantissa(2);
			await send(mockCToken, 'setBorrowIndex', [newIdx]);
			await send(rho, 'advanceBlocks', [10]);
			await send(rho, 'harnessAccrueInterest', []);
			expect(newIdx).toEqNum(await call(rho, 'benchmarkIndexStored', []));
		});

		it.todo(
			'test locked collateral increases in accrue interest after open pay fixed swap'
		);

		/*
		 * TODO: locked collateral min
		 * total liquidity = 0
		 */
	});

	describe('Open pay fixed', () => {
		const duration = bn(345600);
		const rate = bn(1e10);
		const orderSize = mantissa(1);

		beforeEach(async () => {
			await prep(rho._address, mantissa(1), underlying, a1);
			const tx = await send(rho, 'open', [true, orderSize], {
				from: a1,
			});
		});

		// protocol pays float, receives fixed
		it('should open user pay fixed swap', async () => {
			/* lockedCollateral = notionalAmount * swapMinDuration * (maxFloatRate - swapFixedRate);
			 * 					= 1e18 * 345600 * (1e11 - 1e10) / 1e18 = 3.1104E16
			 */
			expect(
				await call(rho, 'avgFixedRateReceivingMantissa', [])
			).toEqNum(rate);
			expect(await call(rho, 'notionalReceivingFixed', [])).toEqNum(
				orderSize
			);

			expect(await call(rho, 'parBlocksReceivingFixed', [])).toEqNum(
				orderSize.mul(duration)
			);

			expect(await call(rho, 'notionalPayingFloat', [])).toEqNum(
				orderSize
			);

			/* userCollateral = notionalAmount * swapMinDuration * (swapFixedRate - minFloatRate);
			 * 			      = 1e18 * 345600 * (1e10 - 0) / 1e18 = 3.456E15
			 */
			expect(await call(underlying, 'balanceOf', [rho._address])).toEqNum(
				supplyAmount.add(mantissa(0.003456))
			);
		});

		it('should accrue interest on user pay fixed debt', async () => {
			// accrue half the duration, or 172800 blocks
			await send(rho, 'advanceBlocks', [duration.div(2)]);
			const benchmarkIdxNew = mantissa(1.203);
			await send(mockCToken, 'setBorrowIndex', [benchmarkIdxNew]);
			await send(rho, 'harnessAccrueInterest', []);

			expect(
				await call(rho, 'avgFixedRateReceivingMantissa', [])
			).toEqNum(rate);
			expect(await call(rho, 'notionalReceivingFixed', [])).toEqNum(
				orderSize
			);

			expect(await call(rho, 'parBlocksReceivingFixed', [])).toEqNum(
				mantissa(1).mul(172800)
			);

			expect(await call(rho, 'notionalPayingFloat', [])).toEqNum(
				orderSize.mul(benchmarkIdxNew).div(benchmarkIndexInit)
			);

			/* totalLiquidityNew += fixedReceived - floatPaid + floatReceived - fixedPaid
			 * fixedReceived = 1e18 + 172800 * 1e10 * 1e18/ 1e18 = 1.728E15
			 * floatPaid = 1e18 * (1.203/1.2 - 1) = 2.5e15
			 * float = 1.203/1.2 => 3% annualized, so protocol losing money here (fixed is ~2%)
			 */
			expect(await call(rho, 'totalLiquidity', [])).toEqNum(
				mantissa(0.999228)
			);

			/* lockedCollateral = maxFloatToPay + fixedToReceive
			 * maxFloatToPay = parBlocksReceivingFixed * maxFloatRate = 172800 * 1e18 * 1e11/1e18 = 1.728e16
			 * fixedToReceive = 172800 * 1e18 * 1e10 = 1.728E15
			 */
			expect(await call(rho, 'harnessAccrueInterest', [])).toEqNum(
				1.5552e16
			);
		});
	});

	let print = (msg, src) => {
		console.log(msg, require('util').inspect(src, false, null, true));
	};

	describe('closePayFixed', () => {
		const duration = bn(345600);
		const actualDuration = bn(345600 + 100);
		const fixedRate = bn(1e10); // 2.1204% interest
		const orderSize = mantissa(10);
		const lateBlocks = bn(600);
		const benchmarkIndexClose = mantissa(1.212); // 1% interest (6% annualized)

		it('should close last swap a little late', async () => {
			await prep(rho._address, mantissa(1), underlying, a1);
			await send(rho, 'open', [true, orderSize], { from: a1 });

			await send(rho, 'advanceBlocks', [actualDuration]);
			let userCollat = bn(
				(345600 *
					orderSize *
					(fixedRate - MIN_FLOAT_MANTISSA_PER_BLOCK)) /
					1e18
			);
			await send(mockCToken, 'setBorrowIndex', [benchmarkIndexClose]);
			const tx = await send(rho, 'close', [
				true,
				benchmarkIndexInit,
				block,
				fixedRate,
				orderSize,
				userCollat,
				a1
			]);

			expect(
				await call(rho, 'avgFixedRateReceivingMantissa', [])
			).toEqNum(0);
			expect(await call(rho, 'notionalReceivingFixed', [])).toEqNum(0);
			expect(await call(rho, 'notionalPayingFloat', [])).toEqNum(0);

			expect(await call(rho, 'parBlocksReceivingFixed', [])).toEqNum(0);
			/* floatLeg = 10e18 * (1.212 / 1.2 - 1) = 0.1e18
			 * fixedLeg = 10e18 * 345700 * 1e10 / 1e18 = 0.03457e18
			 * 1e18 - 0.1e18 + 0.03457e18
			 */
			expect(await call(underlying, 'balanceOf', [rho._address])).toEqNum(
				0.93457e18
			);
		});

		it('should close second last swap a little late', async () => {
			// open swap, open second at end of first, close first.

			await prep(rho._address, mantissa(1), underlying, a1);
			await send(rho, 'open', [true, orderSize], { from: a1 });
			await send(rho, 'advanceBlocks', [actualDuration]);

			await send(model, 'setRate', [bn(2e10)]);
			await send(mockCToken, 'setBorrowIndex', [benchmarkIndexClose]);
			await prep(rho._address, mantissa(1), underlying, a2);
			let tx0 = await send(rho, 'open', [true, orderSize], { from: a2 });
			console.log(tx0.gasUsed);

			expect(
				await call(rho, 'avgFixedRateReceivingMantissa', [])
			).toEqNum(1.5e10);

			let userCollat = bn(
				(345600 *
					orderSize *
					(fixedRate - MIN_FLOAT_MANTISSA_PER_BLOCK)) /
					1e18
			);
			let bal1A1 = await call(underlying, 'balanceOf',[a1]);
			const tx = await logSend(rho, 'close', [
				true,
				benchmarkIndexInit,
				block,
				fixedRate,
				orderSize,
				userCollat,
				a1,
			]);
			console.log(tx.gasUsed);
			expect(
				await call(rho, 'avgFixedRateReceivingMantissa', [])
			).toEqNum(2e10);
			expect(await call(rho, 'notionalReceivingFixed', [])).toEqNum(
				orderSize
			);
			// 345600 * 10e18
			expect(await call(rho, 'parBlocksReceivingFixed', [])).toEqNum(3.456e24);
			expect(await call(rho, 'notionalPayingFloat', [])).toEqNum(
				orderSize
			);
			/* floatLeg = 10e18 * (1.212 / 1.2 - 1) = 0.1e18
			 * fixedLeg = 10e18 * 345700 * 1e10 / 1e18 = 3.457e16
			 * userCollat = 3.456e16
			 * 3.456e16 + 0.1e18 - 3.457e16 = 9.999e16
			 */
			let bal2A1 = await call(underlying, 'balanceOf',[a1]);
			expect(bal2A1 - bal1A1).toEqNum(
				9.999e16
			);
		});
	});

	describe('supply idx', () => {
		it.todo('prove supply idx works');
	});
});
