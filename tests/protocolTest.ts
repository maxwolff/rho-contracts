const { bn, mantissa, sendCall, logSend, hashEncode, cTokens } = require('./util/Helpers');

const MIN_FLOAT_MANTISSA_PER_BLOCK = bn(0);
const MAX_FLOAT_MANTISSA_PER_BLOCK = bn(1e11); // => 2.1024E17 per year via 2102400 blocks / year. ~21%, 3.5% (3.456E16) per 60 days (345600 blocks)

const prep = async (spender, amount, token, who) => {
	await send(token, "allocateTo", [who, amount]);
	await send(token, "approve", [spender, amount], { from: who });
};

let print = (msg, src) => {
	console.log(msg, require('util').inspect(src, false, null, true));
};

const getCloseArgs = (openTx) => {
	const vals = openTx.events.OpenSwap.returnValues;
	return [vals.userPayingFixed, vals.benchmarkIndexInit, vals.initBlock, vals.swapFixedRateMantissa, vals.notionalAmount, vals.userCollateralCTokens, vals.owner];
}

const deployProtocol = async (opts = {}) => {
	const initExchangeRate = bn(2e8);
	const mockCToken = opts.benchmark || (await deploy('MockCToken', [bn(initExchangeRate), '0', 'token1', '18', 'Benchmark Token']));
	const cTokenCollateral = opts.collat || (await deploy('MockCToken', [bn(initExchangeRate), '0', 'token2', '18', 'Collateral Token']));
	const model = await deploy('MockInterestRateModel', []);
	const rho = await deploy('MockRho', [
		model._address,
		mockCToken._address,
		cTokenCollateral._address,
		MIN_FLOAT_MANTISSA_PER_BLOCK,
		MAX_FLOAT_MANTISSA_PER_BLOCK,
	]);
	return {
		mockCToken,
		model,
		cTokenCollateral,
		rho,
		initExchangeRate
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
	let mockCToken, model, cTokenCollateral, rho, initExchangeRate;
	let supplyAmount;
	const block = 100;
	const benchmarkIndexInit = mantissa(1.2);

	beforeEach(async () => {
		({ mockCToken, model, cTokenCollateral, rho, initExchangeRate} = await deployProtocol());
		supplyAmount = bn(1e18).div(2e8);//initExchangeRate;
		await prep(rho._address, supplyAmount, cTokenCollateral, lp);
		await send(rho, 'setBlockNumber', [block]);
		await send(mockCToken, 'setBorrowIndex', [benchmarkIndexInit]);
		await send(rho, 'supplyLiquidity', [supplyAmount], {
			from: lp,
		});
	});

	describe('Add liquidity', () => {
		it('should pull tokens', async () => {
			const lpBalance = await call(cTokenCollateral, 'balanceOf', [lp]);
			expect(0).toEqNum(lpBalance);

			const protocolBalance = await call(cTokenCollateral, 'balanceOf', [
				rho._address,
			]);
			expect(supplyAmount).toEqNum(protocolBalance);
		});

		it('should update account struct', async () => {
			const acct = await call(rho, 'supplyAccounts', [lp]);
			expect(acct.amount.val).toEqNum(supplyAmount);
			expect(acct.lastBlock).toEqNum(block);
			expect(acct.index).toEqNum(mantissa(1));
		});

		it('should update globals', async () => {
			expect(supplyAmount).toEqNum(await call(rho, 'supplierLiquidity', []));
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
		const swapFixedRate = bn(1e10);
		const orderSize = mantissa(1);
		let openTx;

		beforeEach(async () => {
			await prep(rho._address, mantissa(1), cTokenCollateral, a1);
			await send(model, 'setRate', [swapFixedRate]);
			openTx = await send(rho, 'open', [true, orderSize], {
				from: a1,
			});
		});

		it('should emit correct txHash', async () => {
			const closeArgs = getCloseArgs(openTx);
			const computedHash = hashEncode(closeArgs);
			expect(openTx.events.OpenSwap.returnValues.txHash).toEqual(computedHash);

		});

		// protocol pays float, receives fixed
		it('should open user pay fixed swap', async () => {
			/* lockedCollateral = notionalAmount * swapMinDuration * (maxFloatRate - swapFixedRate);
			 * 					= 1e18 * 345600 * (1e11 - 1e10) / 1e18 = 3.1104E16
			 */
			expect(await call(rho, 'getLockedCollateral', [])).toEqNum(3.1104e16);
			expect(
				await call(rho, 'avgFixedRateReceivingMantissa', [])
			).toEqNum(swapFixedRate);
			expect(await call(rho, 'notionalReceivingFixed', [])).toEqNum(
				orderSize
			);

			expect(await call(rho, 'parBlocksReceivingFixed', [])).toEqNum(
				orderSize.mul(duration)
			);

			expect(await call(rho, 'notionalPayingFloat', [])).toEqNum(
				orderSize
			);

			/* userCollateral = notionalAmount * swapMinDuration * (swapFixedRate - minFloatRate) / exchangeRate;
			 * 			      = 1e18 * 345600 * (1e10/1e18 - 0/1e18) / 2e8 = 17280000
			 */
			expect(await call(cTokenCollateral, 'balanceOf', [rho._address])).toEqNum(
				supplyAmount.add(17280000)
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
			).toEqNum(swapFixedRate);
			expect(await call(rho, 'notionalReceivingFixed', [])).toEqNum(
				orderSize
			);

			expect(await call(rho, 'parBlocksReceivingFixed', [])).toEqNum(
				mantissa(1).mul(172800)
			);

			expect(await call(rho, 'notionalPayingFloat', [])).toEqNum(
				orderSize.mul(benchmarkIdxNew).div(benchmarkIndexInit)
			);

			/* supplierLiquidityNew += fixedReceived - floatPaid + floatReceived - fixedPaid
			 * fixedReceived = 1e18 * 172800 * 1e10  / 1e18 = 1.728e15
			 * floatPaid = 1e18 * (1.203/1.2 - 1) = 2.5e15
			 * float = 1.203/1.2 => 3% annualized, so protocol losing money here (fixed is ~2%)
			 * 5e9 + (1.728e15 - 2.5e15)/2e8
			 */
			expect(await call(rho, 'supplierLiquidity', [])).toEqNum(
				4996140000
			);

			/* lockedCollateral = maxFloatToPay + fixedToReceive
			 * maxFloatToPay = parBlocksReceivingFixed * maxFloatRate = 172800 * 1e18 * 1e11/1e18 = 1.728e16
			 * fixedToReceive = 172800 * 1e18 * 1e10 = 1.728E15
			 */
			expect(await call(rho, 'harnessAccrueInterest', [])).toEqNum(
				1.5552e16
			);
		});

		it('should average interest rates', async () => {
			await send(model, 'setRate', [2e10]);
			await prep(rho._address, mantissa(1), cTokenCollateral, a2);
			await send(rho, 'open', [true, orderSize], { from: a2 });
			expect(
				await call(rho, 'avgFixedRateReceivingMantissa', [])
			).toEqNum(1.5e10);

		});
	});

	describe('closePayFixed', () => {
		const duration = 345600;
		const lateBlocks = 400;
		const actualDuration = bn(duration + lateBlocks);// blocks to fast foward
		const swapFixedRate = bn(1e10); // 1e10 * 2102400 /1e18 = 2.1204% annualized interest
		const orderSize = mantissa(10);
		const benchmarkIndexClose = mantissa(1.212); // 1% interest (6% annualized)
		const exchangeRate = 2e8;
		const exchangeRateMantissa = 1e18 * exchangeRate;
		let bal1;
		let closeArgs;

		const setup = async (rate) => {
			await prep(rho._address, mantissa(1), cTokenCollateral, a1);
			bal1 = await call(cTokenCollateral, 'balanceOf',[a1]);
			await send(model, 'setRate', [rate]);
			const tx0 = await send(rho, 'open', [true, orderSize], { from: a1 });
			closeArgs = getCloseArgs(tx0);
			await send(rho, 'advanceBlocks', [actualDuration]);
			await send(mockCToken, 'setBorrowIndex', [benchmarkIndexClose]);
		};

		it('should profit protocol', async () => {
			await setup(bn(3e10));//3e10 * 2102400 /1e18 = ~6.3% annualized interest
			await send(rho, 'close', closeArgs);

			expect(
				await call(rho, 'avgFixedRateReceivingMantissa', [])
			).toEqNum(0);
			expect(await call(rho, 'notionalReceivingFixed', [])).toEqNum(0);
			expect(await call(rho, 'notionalPayingFloat', [])).toEqNum(0);

			expect(await call(rho, 'parBlocksReceivingFixed', [])).toEqNum(0);
			/* floatLeg = 10e18 * (1.212 / 1.2 - 1) = 0.1e18
			 * fixedLeg = 10e18 * 346000 * 3e10 / 1e18 = 0.1038e18
			 * userProfit = (0.1e18 - 0.1038e18) / exchangeRate
			 */
			let bal2 = bn(await call(cTokenCollateral, 'balanceOf',[a1]));
			const userProfit = bal2.sub(bal1);
			expect(userProfit).toEqNum(-0.19e8);
			expect(await call(rho, 'supplierLiquidity', [])).toEqNum(supplyAmount.sub(userProfit));
		});


		it('should profit user', async () => {
			await setup(swapFixedRate);

			await send(rho, 'close', closeArgs);

			expect(
				await call(rho, 'avgFixedRateReceivingMantissa', [])
			).toEqNum(0);
			expect(await call(rho, 'notionalReceivingFixed', [])).toEqNum(0);
			expect(await call(rho, 'notionalPayingFloat', [])).toEqNum(0);

			expect(await call(rho, 'parBlocksReceivingFixed', [])).toEqNum(0);
			/* floatLeg = 10e18 * (1.212 / 1.2 - 1) = 0.1e18
			 * fixedLeg = 10e18 * 346000 * 1e10 / 1e18 = 0.0346e18
			 * userProfit = (0.1e18 - 0.0346e18) / exchangeRate
			 */
			let bal2 = bn(await call(cTokenCollateral, 'balanceOf',[a1]));
			const userProfit = bal2.sub(bal1);
			expect(userProfit).toEqNum(3.27e8);
			expect(await call(rho, 'supplierLiquidity', [])).toEqNum(supplyAmount.sub(userProfit));
		});

		// open swap, open second at end of first, close first.
		it('should close second last swap a little late', async () => {
			await setup(swapFixedRate);
			await prep(rho._address, mantissa(1), cTokenCollateral, a2);

			await send(model, 'setRate', [bn(2e10)]);
			await send(rho, 'open', [true, orderSize], { from: a2 });
			await send(rho, 'close', closeArgs);

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
			 * fixedLeg = 10e18 * 346000 * 1e10 / 1e18 = 0.0346e18
			 * (0.1e18 - 3.46e16) / exchangeRate
			 */
			let bal2 = bn(await call(cTokenCollateral, 'balanceOf',[a1]));
			expect(bal2.sub(bal1)).toEqNum(3.27e8);
		});

		it.todo("check supply index");
	});

	describe('supply idx', () => {
		it.todo('prove supply idx works');
	});
});
