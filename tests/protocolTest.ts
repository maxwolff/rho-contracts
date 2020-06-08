const { bn, mantissa, prep, sendCall, logSend } = require('./util/Helpers');


const MIN_FLOAT_MANTISSA_PER_BLOCK = bn(0);
const MAX_FLOAT_MANTISSA_PER_BLOCK = bn(1e11); // => 2.1024E17 per year via 2102400 blocks / year. ~21%, 3.5% (3.456E16) per 60 days (345600 blocks)

const deployProtocol = async (opts = {}) => {
	const mockCToken = opts.benchmark || (await deploy('MockCToken', []));
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
		MIN_FLOAT_MANTISSA_PER_BLOCK,
		MAX_FLOAT_MANTISSA_PER_BLOCK
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
	const block = 10;
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
			expect(supplyAmount).toEqNum(
				await call(rho, 'totalLiquidity', [])
			);
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
			await expect(send(rho, 'harnessAccrueInterest', [])).rejects.toRevert('Decreasing float rate');
		});

		it('should update benchmark index', async () => {
			let newIdx = mantissa(2);
			await send(mockCToken, 'setBorrowIndex', [newIdx]);
			await send(rho, 'advanceBlocks', [10]);
			await send(rho, 'harnessAccrueInterest', []);
			expect(newIdx).toEqNum(await call(rho, 'benchmarkIndexStored', []));
		});

		it.todo("test locked collateral increases in accrue interest after open pay fixed swap")

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
			const tx = await send(rho, 'openPayFixedSwap', [orderSize], {from: a1});
			console.log(tx.gasUsed)
		});

		// protocol pays float, receives fixed
		it('should open user pay fixed swap', async () => {
			/* lockedCollateral = notionalAmount * swapMinDuration * (maxFloatRate - swapFixedRate);
			 * 					= 1e18 * 345600 * (1e11 - 1e10) / 1e18 = 3.1104E16
			*/
			expect(await call(rho, 'avgFixedRateReceivingMantissa', [])).toEqNum(rate);
			expect(await call(rho, 'fixedNotionalReceiving',[])).toEqNum(orderSize);
			const fixedToReceive = orderSize.mul(duration).mul(rate).div(mantissa(1));//3.456E15
			expect(await call(rho, 'fixedToReceive',[])).toEqNum(fixedToReceive);

			expect(await call(rho, 'parBlocksPayingFloat', [])).toEqNum(orderSize.mul(duration));
			expect(await call(rho, 'floatNotionalPaying',[])).toEqNum(orderSize);

			/* userCollateral = notionalAmount * swapMinDuration * (swapFixedRate - minFloatRate);
			 * 			      = 1e18 * 345600 * (1e10 - 0) / 1e18 = 3.456E15
			*/
			expect(await call(underlying, 'balanceOf', [rho._address])).toEqNum(supplyAmount.add(mantissa(0.003456)));
		});

		it('should accrue interest on user pay fixed debt', async () => {
			// accrue half the duration, or 172800 blocks
			await send(rho, 'advanceBlocks', [duration.div(2)]);
			const benchmarkIdxNew = mantissa(1.203);
			await send(mockCToken, 'setBorrowIndex', [benchmarkIdxNew]);
			await send(rho, 'harnessAccrueInterest', []);

			expect(await call(rho, 'avgFixedRateReceivingMantissa', [])).toEqNum(rate);
			expect(await call(rho, 'fixedNotionalReceiving', [])).toEqNum(orderSize);
			const fixedToReceive = orderSize.mul(duration.div(2)).mul(rate).div(mantissa(1));
			// 1e18 * 172800 * 1e10 / 1e18 = 1.728E15
			expect(fixedToReceive).toEqNum(1.728e15);
			expect(await call(rho, 'fixedToReceive', [])).toEqNum(fixedToReceive);

			expect(await call(rho, 'parBlocksPayingFloat', [])).toEqNum(mantissa(1).mul(172800));
			expect(await call(rho, 'floatNotionalPaying',[])).toEqNum(orderSize.mul(benchmarkIdxNew).div(benchmarkIndexInit));

			/* totalLiquidityNew += fixedReceived - floatPaid + floatReceived - fixedPaid
			 * fixedReceived = 1e18 + 172800 * 1e10 * 1e18/ 1e18 = 1.728E15
			 * floatPaid = 1e18 * (1.203/1.2 - 1) = 2.5e15
			 * float = 1.203/1.2 => 3% annualized, so protocol losing money here (fixed is ~2%)
			 */
			expect(await call(rho, 'totalLiquidity', [])).toEqNum(mantissa(.999228));

			/* lockedCollateral = maxFloatToPay + fixedToReceive
			 * maxFloatToPay = parBlocksPayingFloat * maxFloatRate = 172800 * 1e18 * 1e11/1e18 = 1.728e16
			 * fixedToReceive = 172800 * 1e18 * 1e10 = 1.728E15
			 */
			expect(await call(rho, 'harnessAccrueInterest', [])).toEqNum(1.5552E16);
		})
	});

	describe('closePayFixed', () => {
		const duration = bn(345600);
		const actualDuration = bn(345600 + 100);
		const fixedRate = bn(1e10);
		const orderSize = mantissa(1);
		let lateBlocks = bn(600);

		beforeEach(async () => {
			await prep(rho._address, mantissa(1), underlying, a1);
			let init
			await send(rho, 'openPayFixedSwap', [orderSize], {from: a1});
			await send(rho, 'advanceBlocks', [actualDuration]);
			let userCollat = bn(345600 * orderSize * (fixedRate -MIN_FLOAT_MANTISSA_PER_BLOCK));
			let tx = await logSend(rho, 'closePayFixedSwap', [benchmarkIndexInit, bn(100), fixedRate, MAX_FLOAT_MANTISSA_PER_BLOCK, orderSize, userCollat, root]);
			console.log(tx);
		});

		it('should close swap', async () => {
			expect(1).toEqual(1);
		})

		it.todo('accrue at various times');
	});

	describe('supply idx', () => {
		it.todo('prove supply idx works');
	});
});
