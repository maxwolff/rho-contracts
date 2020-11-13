const { bn, mantissa, hashEncode, str, MAX_UINT } = require('./util/Helpers');

const MIN_FLOAT_MANTISSA_PER_BLOCK = bn(0);
const MAX_FLOAT_MANTISSA_PER_BLOCK = bn(1e11); // => 2.1024E17 per year via 2102400 blocks / year. ~21%, 3.5% (3.456E16) per 60 days (345600 blocks)
const INIT_EXCHANGE_RATE = bn(2e8);
const SWAP_MIN_DURATION = bn(345600);// 60 days in blocks, assuming 15s blocks
const SUPPLY_MIN_DURATION = bn(172800);
const BLOCKS_PER_YEAR = bn(2102400);

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

const prep = async (spender, amount, token, who) => {
	await send(token, "allocateTo", [who, amount]);
	await send(token, "approve", [spender, amount], { from: who });
};

const getCloseArgs = (openTx) => {
	const vals = openTx.events.OpenSwap.returnValues;
	return [vals.userPayingFixed, vals.benchmarkIndexInit, vals.initBlock, vals.swapFixedRateMantissa, vals.notionalAmount, vals.userCollateralCTokens, vals.owner];
}

const deployProtocol = async (opts = {}) => {
	const cToken = await deploy('MockCToken', [INIT_EXCHANGE_RATE, bn(2e10), '0', 'token2', '18', 'Collateral Token']);
	const comp = await deploy('FaucetToken', ['0', 'COMP', '18', 'Compound Governance Token']);
	const model = opts.mockModel ? await deploy('MockInterestRateModel', []) : await deploy('InterestRateModel', modelParams);
	const rho = await deploy('MockRho', [
		model._address,
		cToken._address,
		comp._address,
		MIN_FLOAT_MANTISSA_PER_BLOCK,
		MAX_FLOAT_MANTISSA_PER_BLOCK,
		SWAP_MIN_DURATION,
		SUPPLY_MIN_DURATION,
		saddle.accounts[0],
		opts.liquidityLimit || MAX_UINT
	]);
	const rhoLens = await deploy('RhoLensV1', [rho._address]);

	return {
		model,
		cToken,
		rho,
		rhoLens,
		comp
	};
};

describe('Protocol Integration Tests', () => {
	const [root, lp, a1, a2, ...accounts] = saddle.accounts;
	let model, cToken, rho, rhoLens, comp;
	const supplyAmount = bn(100e18).div(INIT_EXCHANGE_RATE);
	const block = 100;
	const benchmarkIndexInit = mantissa(1.2);

	beforeEach(async () => {
		({ model, cToken, rho, rhoLens, comp} = await deployProtocol({MockInterestRateModel: false}));
		await prep(rho._address, supplyAmount, cToken, lp);
		await send(cToken, 'setBorrowIndex', [benchmarkIndexInit]);
		await send(rho, 'supply', [supplyAmount], {
			from: lp,
		});
	});

	it('open', async () => {
		await prep(rho._address, mantissa(1), cToken, a1);
		const {swapFixedRateMantissa, userCollateralCTokens, protocolIsCollateralized} = await call(rhoLens, 'getHypotheticalOrderInfo', [true, mantissa(1)]);
		const tx = await send(rho, 'openPayFixedSwap', [mantissa(1), swapFixedRateMantissa], {from: a1});

		expect(tx.events.OpenSwap.returnValues.swapFixedRateMantissa).toEqNum(swapFixedRateMantissa);
		expect(30000026517).toAlmostEqual(swapFixedRateMantissa);
		expect(tx.events.OpenSwap.returnValues.userCollateralCTokens).toEqNum(userCollateralCTokens);

		const rateFactor = await call(rho, 'rateFactor', []);
		expect(rateFactor).toEqNum(7.5e11);
	});

	it('increment bororow index', async () => {
		expect(await call(rho, 'getBenchmarkIndex', [])).toEqNum(benchmarkIndexInit);
		expect(await call(cToken, 'borrowRatePerBlock', [])).toEqNum(2e10);
		await send(rho, 'advanceBlocks', [5000]);
		// 1.2e18 + 1.2e18 * (5000 * 2e10/ 1e18)
		expect(await call(rho, 'getBenchmarkIndex', [])).toEqNum(mantissa(1.20012));
	});
});

describe('Protocol Unit Tests', () => {
	// root just deploys, has no actions with protocol
	const [root, lp, a1, a2, ...accounts] = saddle.accounts;
	let model, cToken, rho, rhoLens, comp;
	const supplyAmount = bn(1e18).div(INIT_EXCHANGE_RATE);//50e8
	const benchmarkIndexInit = mantissa(1.2);

	// rho and ctoken contract start with mocked bn of 100
	beforeEach(async () => {
		({ model, cToken, rho, rhoLens, comp} = await deployProtocol({mockModel: true}));
		await prep(rho._address, supplyAmount, cToken, lp);
		await send(cToken, 'setBorrowIndex', [benchmarkIndexInit]);
		await send(rho, 'supply', [supplyAmount], {
			from: lp,
		});
	});

	describe('Add liquidity', () => {
		it('should pull tokens', async () => {
			const lpBalance = await call(cToken, 'balanceOf', [lp]);
			expect(0).toEqNum(lpBalance);

			const protocolBalance = await call(cToken, 'balanceOf', [
				rho._address,
			]);
			expect(supplyAmount).toEqNum(protocolBalance);
		});

		it('should update account struct', async () => {
			const {amount, lastBlock, index} = await call(rho, 'supplyAccounts', [lp]);
			expect(amount).toEqNum(supplyAmount);
			expect(lastBlock).toEqNum(100);
			expect(index).toEqNum(mantissa(1));
		});

		it('should update globals', async () => {
			expect(supplyAmount).toEqNum(await call(rho, 'supplierLiquidity', []));
			expect(benchmarkIndexInit).toEqNum(
				await call(rho, 'benchmarkIndexStored', [])
			);
		});

		it('should trues up on second supply', async () => {
			// Prep a swap that increases the supply idx: same as closePayFixed/"should close swap and profit protocol"

			const swapFixedRate = bn(3e10);
			const orderSize = mantissa(10);
			await prep(rho._address, mantissa(1), cToken, a1);
			await send(model, 'setRate', [swapFixedRate]);
			const tx = await send(rho, 'openPayFixedSwap', [orderSize, swapFixedRate], {
				from: a1
			});
			await send(rho, 'advanceBlocksProtocol', [bn(SWAP_MIN_DURATION).add(400)]);
			await send(cToken, 'setBorrowIndex', [mantissa(1.212)]);
			await send(rho, 'close', getCloseArgs(tx));
			expect(await call(rho, 'supplyIndex', [])).toEqNum(1.0038e18);

			await prep(rho._address, 10e8, cToken, lp);
			await send(rho, 'supply', [10e8], {
				from: lp,
			});

			// 50e8 * 1.0038 + 10e8 = 60.19
			let {amount, lastBlock, index} = await call(rho, 'supplyAccounts', [lp]);
			expect(amount).toEqNum(60.19e8);
			const blockNum = await call(rho, 'getBlockNumber', []);
			expect(lastBlock).toEqNum(blockNum);
			expect(index).toEqNum(1.0038e18);

			// if previously fully withdrawn, should correctly supply again
			await send(rho, 'setBlockNumber', [600000]);
			await send(rho, 'remove', [0], {from: lp});

			({amount, lastBlock, index} = await call(rho, 'supplyAccounts', [lp]));
			expect(amount).toEqNum(0);
			expect(lastBlock).toEqNum(600000);
			expect(index).toEqNum(1.0038e18);

			await send(rho, 'setBlockNumber', [600001]);

			await prep(rho._address, 10e8, cToken, lp);
			await send(rho, 'supply', [10e8], {
				from: lp,
			});

			({amount, lastBlock, index} = await call(rho, 'supplyAccounts', [lp]));
			expect(amount).toEqNum(10e8);
			expect(lastBlock).toEqNum(600001);
			expect(index).toEqNum(1.0038e18);
		});
	});

	describe('Remove liquidity', () => {
		const lateBlocks = 400;
		const actualDuration = SWAP_MIN_DURATION.add(lateBlocks);// blocks to fast foward
		const swapFixedRate = bn(1e10); // 1e10 * 2102400 /1e18 = 2.1204% annualized interest
		const benchmarkIndexClose = mantissa(1.212); // 1% interest (6% annualized)
		let openTx;

		const setup = async () => {
			await prep(rho._address, mantissa(1), cToken, a1);
			await send(model, 'setRate', [bn(1e10)]);
			openTx = await send(rho, 'openPayFixedSwap', [mantissa(10), 1e10], { from: a1 });
		};

		it('should succeed in removing liquidity at protocols loss', async () => {
			await setup();
			const closeArgs = getCloseArgs(openTx);
			await send(rho, 'advanceBlocksProtocol', [actualDuration]);
			await send(cToken, 'setBorrowIndex', [benchmarkIndexClose]);
			await send(rho, 'close', closeArgs);
			/* floatLeg = 10e18 * (1.212 / 1.2 - 1) = 0.1e18
			 * fixedLeg = 10e18 * 346000 * 1e10 / 1e18 = 0.0346e18
			 * userProfit = (0.1e18 - 0.0346e18) / 2e8 (exchangeRate)
			 * userProfit = 3.27e8
			 * LP bal diff: 50e8 - 3.27e8 = 46.73e8
			 */
			const balPrev = await call(cToken, 'balanceOf', [lp]);
			await send(rho, 'remove', [0], {from: lp});
			const balAfter = await call(cToken, 'balanceOf', [lp]);
			expect(await call(rho, 'supplierLiquidity', [])).toEqNum(0);
			expect(bn(balAfter).sub(balPrev)).toEqNum(46.73e8);

			/* supplyIndex = 1e18 * 46.73e8 / 50e8 = 0.9346e18 */
			expect(await call(rho, 'supplyIndex',[])).toEqNum(0.9346e18);
		});

		// remove liquidity half way through swap
		it('should succeed in removing liquidity early', async () => {
			await setup();
			await send(rho, 'advanceBlocksProtocol', [SUPPLY_MIN_DURATION]);
			await send(cToken, 'setBorrowIndex', [mantissa(1.206)]);//0.5% interests, 6% annual
			// lockedCollateral = notionalAmount * swapMinDuration * (maxFloatRate - swapFixedRate);
			// 	= 10e18 * 172800 * (1e11 - 1e10) / 1e18 / 2e8 = 7.776e8;
			const {lockedCollateral, supplierLiquidity} = await call(rhoLens, 'getSupplyCollateralState', []);
			expect(lockedCollateral.val).toEqNum(7.776e8);
			expect(supplierLiquidity.val).toEqNum(48.364e8);
			await send(rho, 'remove', [bn(40e8)], {from: lp});
			/* floatLeg = 10e18 * (1.206 / 1.2 - 1) = 0.05e18
			 * fixedLeg = 10e18 * 172800 * 1e10 /1e18 = 0.01728e18
			 * supplyNew = 50e8 - (0.01728e18 - 0.05e18)/2e8) = 48.364
			 * supplyIndexNew = 48.364e8 / 50e8
			 * unlockedCollat = 48.364 - 7.776e8
			 */
			expect(await call(rho, 'supplyIndex',[])).toEqNum(0.96728e18);
		});

		it('should revert if not enough unlocked collateral', async () => {
			await send(rho, 'advanceBlocksProtocol', [SUPPLY_MIN_DURATION]);
			await setup();
			/* lockedCollateral = notionalAmount * swapMinDuration * (maxFloatRate - swapFixedRate);
			 * 					= 10e18 * 345600 * (1e11 - 1e10) / 1e18 / 2e8
			 */
			const {lockedCollateral} = await call(rhoLens, 'getSupplyCollateralState', []);
			expect(lockedCollateral.val).toEqNum(15.552e8);
			expect(await call(rho, 'supplierLiquidity', [])).toEqNum(bn(50e8));
			// unlocked = 50e8 - 1.5552e8 = 34.4448e8
			await expect(send(rho, 'remove', [bn(35e8)], {from: lp})).rejects.toRevert('Removing more liquidity than is unlocked');
			await send(rho, 'remove', [bn(34e8)], {from: lp});
		});

		it('should revert if not held for long enough', async () => {
			await setup();
			await expect(send(rho, 'remove', [bn(49e8)], {from: lp})).rejects.toRevert('Liquidity must be supplied a minimum duration');
		});

		it('should revert if not active supplier', async () => {
			await setup();
			await expect(send(rho, 'remove', [bn(1e8)], {from: root})).rejects.toRevert('Must withdraw from active account');
		});
	});

	describe('Accrue Interest', () => {
		it('should revert if index decreases', async () => {
			await send(rho, 'advanceBlocksProtocol', [1]);
			await send(cToken, 'setBorrowIndex', [mantissa(0.9)]);
			await expect(
				send(rho, 'harnessAccrueInterest', [])
			).rejects.toRevert('subtraction underflow');
		});

		it('should update and true up benchmark index', async () => {
			await send(rho, 'advanceBlocks', [10000]);
			await send(rho, 'harnessAccrueInterest', []);
			// = 1.2e18 * (1e18 + 10000 * 2e10) / 1e18
			expect(1.20024e18).toEqNum(await call(rho, 'benchmarkIndexStored', []));
		});
	});

	describe('open user paying fixed', () => {

		describe('reverts', () => {
			const swapFixedRate = bn(1e10);
			it('insufficient collateral', async () => {
				await prep(rho._address, mantissa(1), cToken, a1);

				await send(model, 'setRate', [swapFixedRate]);
				/* lockedCollateral = notionalAmount * swapMinDuration * (maxFloatRate - swapFixedRate);
				 * 					= 40e18 * 345600 * (1e11 - 1e10) / 1e18 / 2e8 = 62.208e8
				 * supplyAmount (50e8) < hypotheticalLockedCollateral ()
				 */
				await expect(send(rho, 'openPayFixedSwap', [mantissa(40), swapFixedRate], {from: a1})).rejects.toRevert('Insufficient protocol collateral');
			});

			it('minimum swap size', async () => {
				await prep(rho._address, mantissa(1), cToken, a1);
				await send(model, 'setRate', [bn(1e10)]);
				await expect(send(rho, 'openPayFixedSwap', [mantissa(0.1), swapFixedRate], {from: a1})).rejects.toRevert('Swap notional amount must exceed minimum');
			});

			it('pay fixed rate too high', async () => {
				await prep(rho._address, mantissa(1), cToken, a1);
				await send(model, 'setRate', [bn(1.1e10)]);
				await expect(send(rho, 'openPayFixedSwap', [mantissa(1), swapFixedRate], {from: a1})).rejects.toRevert('The fixed rate Rho would receive is above user\'s limit');
			});
		});

		describe('succeeds', () => {
			const swapFixedRate = bn(1e10);
			const orderSize = mantissa(1);
			let openTx;

			beforeEach(async () => {
				await prep(rho._address, mantissa(1), cToken, a1);
				await send(model, 'setRate', [swapFixedRate]);
				openTx = await send(rho, 'openPayFixedSwap', [orderSize, swapFixedRate], {
					from: a1
				});
			});

			it('should emit correct swapHash', async () => {
				const closeArgs = getCloseArgs(openTx);
				const computedHash = hashEncode(closeArgs);
				expect(openTx.events.OpenSwap.returnValues.swapHash).toEqual(computedHash);
			});

			// protocol pays float, receives fixed
			it('should open user pay fixed swap', async () => {
				/* lockedCollateral = notionalAmount * swapMinDuration * (maxFloatRate - swapFixedRate);
				 * 					= 1e18 * 345600 * (1e11 - 1e10) / 1e18 / 2e8
				 */
				const {lockedCollateral, unlockedCollateral} = await call(rhoLens, 'getSupplyCollateralState', []);
				expect(lockedCollateral.val).toEqNum(1.5552e8);

				expect(
					await call(rho, 'avgFixedRateReceiving', [])
				).toEqNum(swapFixedRate);
				expect(await call(rho, 'notionalReceivingFixed', [])).toEqNum(
					orderSize
				);

				expect(await call(rho, 'parBlocksReceivingFixed', [])).toEqNum(
					orderSize.mul(SWAP_MIN_DURATION)
				);

				expect(await call(rho, 'notionalPayingFloat', [])).toEqNum(
					orderSize
				);

				/* userCollateral = notionalAmount * swapMinDuration * (swapFixedRate - minFloatRate) / exchangeRate;
				 * 			      = 1e18 * 345600 * (1e10/1e18 - 0/1e18) / 2e8 = 0.1728e8
				 */
				expect(await call(cToken, 'balanceOf', [rho._address])).toEqNum(
					supplyAmount.add(0.1728e8)
				);
			});

			it('should accrue interest on user pay fixed debt', async () => {
				// accrue half the duration, or 172800 blocks
				await send(rho, 'advanceBlocksProtocol', [SWAP_MIN_DURATION.div(2)]);
				const benchmarkIdxNew = mantissa(1.203);
				await send(cToken, 'setBorrowIndex', [benchmarkIdxNew]);
				await send(rho, 'harnessAccrueInterest', []);

				expect(
					await call(rho, 'avgFixedRateReceiving', [])
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
				 * 50e8 + (1.728e15 - 2.5e15)/2e8
				 */
				expect(await call(rho, 'supplierLiquidity', [])).toEqNum(
					49.9614e8
				);

				/* lockedCollateral = maxFloatToPay - fixedToReceive
				 * maxFloatToPay = parBlocksReceivingFixed * maxFloatRate = 172800 * 1e18 * 1e11 / 1e18 / 2e8
				 * fixedToReceive = 172800 * 1e18 * 1e10 / 1e18 / 2e8
				 * 0.864e8 - 0.0864e8 = 0.7776e8
				 */
				const {lockedCollateral} = await call(rhoLens, 'getSupplyCollateralState', []);
				expect(lockedCollateral.val).toEqNum(0.7776e8);
			});

			it('should average interest rates', async () => {
				await send(model, 'setRate', [2e10]);
				await prep(rho._address, mantissa(1), cToken, a2);
				await send(rho, 'openPayFixedSwap', [orderSize, 2e10], { from: a2 });
				expect(
					await call(rho, 'avgFixedRateReceiving', [])
				).toEqNum(1.5e10);
			});
		});
	});

	describe('open user receiving fixed', () => {
		describe('reverts', () => {
			const swapFixedRate = bn(5e10);
			it('insufficient collateral', async () => {
				await prep(rho._address, mantissa(1), cToken, a1);
				await send(model, 'setRate', [swapFixedRate]);
				/* lockedCollateral = notionalAmount * swapMinDuration * (swapFixedRate - minFloatRate);
				 * 					= 70e18 * 345600 * (5e10 - 0) / 1e18 / 2e8 = 60.48e8
				 * supplyAmount (50e8) < 60.48e8
				 */
				await expect(send(rho, 'openReceiveFixedSwap', [mantissa(70), swapFixedRate], {from: a1})).rejects.toRevert('Insufficient protocol collateral');
			});

			it('minimum swap size', async () => {
				await prep(rho._address, mantissa(1), cToken, a1);
				await send(model, 'setRate', [swapFixedRate]);
				await expect(send(rho, 'openReceiveFixedSwap', [mantissa(0.1), swapFixedRate], {from: a1})).rejects.toRevert('Swap notional amount must exceed minimum');
			});

			it('pay fixed rate too high', async () => {
				await prep(rho._address, mantissa(1), cToken, a1);
				await send(model, 'setRate', [4.9e10]);
				await expect(send(rho, 'openReceiveFixedSwap', [mantissa(1), swapFixedRate], {from: a1})).rejects.toRevert('The fixed rate Rho would pay is below user\'s limit');
			});
		});

		describe('succeeds', () => {
			const swapFixedRate = bn(1e10);
			const orderSize = mantissa(1);
			let openTx;

			beforeEach(async () => {
				await prep(rho._address, mantissa(1), cToken, a1);
				await send(model, 'setRate', [swapFixedRate]);
				openTx = await send(rho, 'openReceiveFixedSwap', [orderSize, swapFixedRate], {
					from: a1
				});
			});

			it('should emit correct swapHash', async () => {
				const closeArgs = getCloseArgs(openTx);
				const computedHash = hashEncode(closeArgs);
				expect(openTx.events.OpenSwap.returnValues.swapHash).toEqual(computedHash);
			});

			// protocol pays float, receives fixed
			it('should open user receive fixed swap', async () => {
				/* lockedCollateral = notionalAmount * swapMinDuration * (swapFixedRate - minFloatRate);
				 * 					= 1e18 * 345600 * (1e10 - 0) / 1e18 / 2e8
				 */
				const {lockedCollateral} = await call(rhoLens, 'getSupplyCollateralState', []);
				expect(lockedCollateral.val).toEqNum(0.1728e8);
				expect(
					await call(rho, 'avgFixedRatePaying', [])
				).toEqNum(swapFixedRate);
				expect(await call(rho, 'notionalPayingFixed', [])).toEqNum(
					orderSize
				);

				expect(await call(rho, 'parBlocksPayingFixed', [])).toEqNum(
					orderSize.mul(SWAP_MIN_DURATION)
				);

				expect(await call(rho, 'notionalReceivingFloat', [])).toEqNum(
					orderSize
				);

				/* userCollateral = notionalAmount * swapMinDuration * (maxFloatRate - swapFixedRate) / exchangeRate;
				 * 			      = 1e18 * 345600 * (1e11 - 1e10) / 1e18 / 2e8 = 1.5552e8
				 */
				expect(await call(cToken, 'balanceOf', [rho._address])).toEqNum(
					supplyAmount.add(1.5552e8)
				);
			});

			// accrue half the duration, or 172800 blocks
			it('should accrue interest on user pay fixed debt', async () => {
				await send(rho, 'advanceBlocksProtocol', [SWAP_MIN_DURATION.div(2)]);
				const benchmarkIdxNew = mantissa(1.203);
				await send(cToken, 'setBorrowIndex', [benchmarkIdxNew]);
				await send(rho, 'harnessAccrueInterest', []);

				expect(
					await call(rho, 'avgFixedRatePaying', [])
				).toEqNum(swapFixedRate);
				expect(await call(rho, 'notionalPayingFixed', [])).toEqNum(
					orderSize
				);

				expect(await call(rho, 'parBlocksPayingFixed', [])).toEqNum(
					mantissa(1).mul(172800)
				);

				expect(await call(rho, 'notionalReceivingFloat', [])).toEqNum(
					orderSize.mul(benchmarkIdxNew).div(benchmarkIndexInit)
				);

				/* supplierLiquidityNew += fixedReceived - floatPaid + floatReceived - fixedPaid
				 * fixedPaid = 1e18 * 172800 * 1e10  / 1e18 = 1.728e15
				 * floatReceived = 1e18 * (1.203/1.2 - 1) = 2.5e15
				 * 50e8 + (2.5e15 - 1.728e15)/2e8 = 50.0386e8
				 */
				expect(await call(rho, 'supplierLiquidity', [])).toEqNum(
					50.0386e8
				);

				/* lockedCollateral = fixedToPay - minFloatToReceive
				 * minFloatToReceive = parBlocksPayingFixed * minFloatRate = 0
				 * fixedToPay = 172800 * 1e18 * 1e10 / 1e18 / 2e8 = 0.864e8
				 */
				const {lockedCollateral} = await call(rhoLens, 'getSupplyCollateralState', []);
				expect(lockedCollateral.val).toEqNum(0.0864e8);
			});

			it('should average interest rates', async () => {
				await send(model, 'setRate', [2e10]);
				await prep(rho._address, mantissa(1), cToken, a2);
				await send(rho, 'openReceiveFixedSwap', [orderSize, 2e10], { from: a2 });
				expect(
					await call(rho, 'avgFixedRatePaying', [])
				).toEqNum(1.5e10);

			});
		});
	});

	describe('closePayFixed', () => {
		const actualDuration = bn(SWAP_MIN_DURATION).add(400);// blocks to fast foward
		const swapFixedRate = bn(1e10); // 1e10 * 2102400 /1e18 = 2.1204% annualized interest
		const orderSize = mantissa(10);
		const benchmarkIndexClose = mantissa(1.212); // 1% interest (6% annualized)
		let bal1;
		let closeArgs;

		const setup = async (rate) => {
			await prep(rho._address, mantissa(1), cToken, a1);
			bal1 = await call(cToken, 'balanceOf',[a1]);
			await send(model, 'setRate', [rate]);
			const tx0 = await send(rho, 'openPayFixedSwap', [orderSize, rate], { from: a1 });
			closeArgs = getCloseArgs(tx0);
			await send(rho, 'advanceBlocksProtocol', [actualDuration]);
			await send(cToken, 'setBorrowIndex', [benchmarkIndexClose]);
		};

		it.only('gas test', async () => {
			await setup(bn(3e10));
			const tx = await send(rho, 'close', closeArgs);
			console.log(tx.gasUsed);
		});

		it('should close swap and profit protocol', async () => {
			await setup(bn(3e10));//3e10 * 2102400 /1e18 = ~6.3% annualized interest
			await send(rho, 'close', closeArgs);

			expect(
				await call(rho, 'avgFixedRateReceiving', [])
			).toEqNum(0);
			expect(await call(rho, 'notionalReceivingFixed', [])).toEqNum(0);
			expect(await call(rho, 'notionalPayingFloat', [])).toEqNum(0);

			expect(await call(rho, 'parBlocksReceivingFixed', [])).toEqNum(0);
			/* floatLeg = 10e18 * (1.212 / 1.2 - 1) = 0.1e18
			 * fixedLeg = 10e18 * 346000 * 3e10 / 1e18 = 0.1038e18
			 * userProfit = (0.1e18 - 0.1038e18) / 2e8 (exchangeRate)
			 */
			let bal2 = bn(await call(cToken, 'balanceOf',[a1]));
			const userProfit = bal2.sub(bal1);
			expect(userProfit).toEqNum(-0.19e8);
			expect(await call(rho, 'supplierLiquidity', [])).toEqNum(supplyAmount.sub(userProfit));
			expect(await call(rho, 'supplyIndex', [])).toEqNum(1.0038e18);
		});


		it('should close swap and profit user', async () => {
			await setup(swapFixedRate);

			await send(rho, 'close', closeArgs);
			/* floatLeg = 10e18 * (1.212 / 1.2 - 1) = 0.1e18
			 * fixedLeg = 10e18 * 346000 * 1e10 / 1e18 = 0.0346e18
			 * userProfit = (0.1e18 - 0.0346e18) / 2e8 (exchangeRate)
			 */
			let bal2 = bn(await call(cToken, 'balanceOf',[a1]));
			const userProfit = bal2.sub(bal1);
			expect(userProfit).toEqNum(3.27e8);
			expect(await call(rho, 'supplierLiquidity', [])).toEqNum(supplyAmount.sub(userProfit));
			expect(await call(rho, 'supplyIndex', [])).toEqNum(0.9346e18);
		});

		it('should close late pay fixed swap w/o underflows even if user payout is 0', async () => {
			await setup(swapFixedRate);

			// fixedLeg >> floatLeg
			await send(rho, 'advanceBlocksProtocol', [actualDuration.mul(100)]);

			const res = await send(rho, 'close', closeArgs);
			expect(res.events.CloseSwap.returnValues.userPayout).toEqNum('0');
		});

		it('should close late pay fixed swap w/o underflows even if user payout is the whole pool', async () => {
			await setup(swapFixedRate);
			const bal = await call(cToken, 'balanceOf', [rho._address]);

			// floatLeg >> fixedLeg
			await send(rho, 'advanceBlocksProtocol', [actualDuration.mul(100)]);
			await send(cToken, 'setBorrowIndex', [mantissa(2)]);

			const res = await send(rho, 'close', closeArgs);
			expect(res.events.CloseSwap.returnValues.userPayout).toEqNum(bal);
		});

		// open swap, open second at end of first, close first.
		it('should close second last swap a little late', async () => {
			await setup(swapFixedRate);
			await prep(rho._address, mantissa(1), cToken, a2);

			await send(model, 'setRate', [bn(2e10)]);
			await send(rho, 'openPayFixedSwap', [orderSize, 2e10], { from: a2 });
			await send(rho, 'close', closeArgs);

			expect(
				await call(rho, 'avgFixedRateReceiving', [])
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
			 * (0.1e18 - 3.46e16) / 2e8 (exchangeRate)
			 */
			let bal2 = bn(await call(cToken, 'balanceOf',[a1]));
			expect(bal2.sub(bal1)).toEqNum(3.27e8);
		});
	});

	// user receiving fixed
	describe('closeReceiveFixed', () => {
		const actualDuration = bn(SWAP_MIN_DURATION).add(400);// blocks to fast foward
		const swapFixedRate = bn(1e10); // 1e10 * 2102400 /1e18 = 2.1204% annualized interest
		const orderSize = mantissa(10);
		const benchmarkIndexClose = mantissa(1.212); // 1% interest (6% annualized)
		let bal1;
		let closeArgs;

		const setup = async (rate) => {
			await prep(rho._address, mantissa(1), cToken, a1);
			bal1 = await call(cToken, 'balanceOf',[a1]);
			await send(model, 'setRate', [rate]);
			const tx0 = await send(rho, 'openReceiveFixedSwap', [orderSize, rate], { from: a1 });
			closeArgs = getCloseArgs(tx0);
			await send(rho, 'advanceBlocksProtocol', [actualDuration]);
			await send(cToken, 'setBorrowIndex', [benchmarkIndexClose]);
		};

		it('should close swap and profit user', async () => {
			await setup(bn(3e10));//3e10 * 2102400 /1e18 = ~6.3% annualized interest
			await send(rho, 'close', closeArgs);

			expect(
				await call(rho, 'avgFixedRatePaying', [])
			).toEqNum(0);
			expect(await call(rho, 'notionalPayingFixed', [])).toEqNum(0);
			expect(await call(rho, 'notionalReceivingFloat', [])).toEqNum(0);
			expect(await call(rho, 'parBlocksPayingFixed', [])).toEqNum(0);
			/* floatLeg = 10e18 * (1.212 / 1.2 - 1) = 0.1e18
			 * fixedLeg = 10e18 * 346000 * 3e10 / 1e18 = 0.1038e18
			 * userProfit = (0.1038e18 - 0.1e18) / 2e8
			 */
			let bal2 = bn(await call(cToken, 'balanceOf',[a1]));
			const userProfit = bal2.sub(bal1);
			expect(userProfit).toEqNum(0.19e8);
			expect(await call(rho, 'supplierLiquidity', [])).toEqNum(supplyAmount.sub(userProfit));
			expect(await call(rho, 'supplyIndex', [])).toEqNum(0.9962e18);
		});


		it('should close swap and profit protocol', async () => {
			await setup(swapFixedRate);

			await send(rho, 'close', closeArgs);
			/* floatLeg = 10e18 * (1.212 / 1.2 - 1) = 0.1e18
			 * fixedLeg = 10e18 * 346000 * 1e10 / 1e18 = 0.0346e18
			 * userProfit = (0.0346e18 - 0.1e18) / 2e8
			 */
			let bal2 = bn(await call(cToken, 'balanceOf',[a1]));
			const userProfit = bal2.sub(bal1);
			expect(userProfit).toEqNum(-3.27e8);
			expect(await call(rho, 'supplierLiquidity', [])).toEqNum(supplyAmount.sub(userProfit));
			expect(await call(rho, 'supplyIndex', [])).toEqNum(1.0654e18);
		});

		it('should close late rec fixed swap without underflowing if very late, user payout is 0', async () => {
			await setup(swapFixedRate);
			
			// floatLeg >> fixedLeg
			await send(rho, 'advanceBlocksProtocol', [actualDuration.mul(100)]);
			await send(cToken, 'setBorrowIndex', [mantissa(2)]);

			const res = await send(rho, 'close', closeArgs);
			expect(res.events.CloseSwap.returnValues.userPayout).toEqNum('0');
		});

		it('should close rec fixed swap if payout is whole pool', async () => {
			await setup(swapFixedRate);
			const bal = await call(cToken, 'balanceOf', [rho._address]);
			
			// fixedLeg >> floatLeg
			await send(rho, 'advanceBlocksProtocol', [actualDuration.mul(100)]);

			const res = await send(rho, 'close', closeArgs);
			expect(res.events.CloseSwap.returnValues.userPayout).toEqNum(bal);
		});

		// open swap, open second at end of first, close first.
		it('should close second last swap a little late', async () => {
			await setup(swapFixedRate);
			await prep(rho._address, mantissa(1), cToken, a2);

			await send(model, 'setRate', [bn(2e10)]);
			await send(rho, 'openReceiveFixedSwap', [orderSize, 2e10], { from: a2 });
			await send(rho, 'close', closeArgs);

			expect(
				await call(rho, 'avgFixedRatePaying', [])
			).toEqNum(2e10);
			expect(await call(rho, 'notionalPayingFixed', [])).toEqNum(
				orderSize
			);
			// 345600 * 10e18
			expect(await call(rho, 'parBlocksPayingFixed', [])).toEqNum(3.456e24);
			expect(await call(rho, 'notionalReceivingFloat', [])).toEqNum(
				orderSize
			);
			/* floatLeg = 10e18 * (1.212 / 1.2 - 1) = 0.1e18
			 * fixedLeg = 10e18 * 346000 * 1e10 / 1e18 = 0.0346e18
			 * (3.46e16 - 0.1e18) / 2e8 (exchangeRate)
			 */
			let bal2 = bn(await call(cToken, 'balanceOf',[a1]));
			expect(bal2.sub(bal1)).toEqNum(-3.27e8);
		});
	});

	describe('admin', () => {

		it('should set interest rate model', async () => {
			const model2 = await deploy('MockInterestRateModel', []);
			await expect(
				send(rho, '_setInterestRateModel', [model2._address], {from: a1})
			).rejects.toRevert('Must be admin to set interest rate model');
			await send(rho, '_setInterestRateModel',[model2._address], {from: root});
			expect(await call(rho, 'interestRateModel',[])).toBe(model2._address);
		});

		it('should set collateral requirements', async () => {
			await send(rho, '_setCollateralRequirements',[0.5e10, 0.5e11], {from:root});
			expect(await call(rho, 'minFloatRate',[])).toEqNum(0.5e10);
			expect(await call(rho, 'maxFloatRate',[])).toEqNum(0.5e11);
		});

		it('should set collateral requirements', async () => {
			await send(rho, '_setCollateralRequirements',[0.5e10, 0.5e11], {from:root});
			expect(await call(rho, 'minFloatRate',[])).toEqNum(0.5e10);
			expect(await call(rho, 'maxFloatRate',[])).toEqNum(0.5e11);
		});

		it('should set limit', async () => {
			await expect(send(rho, '_setLiquidityLimit', [bn(44e8)], {from:a1})).rejects.toRevert('Must be admin to set liqiudity limit');
			await send(rho, '_setLiquidityLimit', [bn(44e8)], {from:root});
			expect(await call(rho, 'liquidityLimit')).toEqNum(bn(44e8));
		});

		it('should set pause', async () => {
			await expect(send(rho, '_pause',[true], {from:a1})).rejects.toRevert('Must be admin to pause');
			await send(rho, '_pause',[true], {from:root});
			await prep(rho._address, mantissa(1), cToken, lp);
			await expect(send(rho, 'supply', [1], {from: lp})).rejects.toRevert("Market paused");
			await expect(send(rho, 'openPayFixedSwap', [1, 0], {from: a1})).rejects.toRevert("Market paused");
		});

		it('should transfer comp', async () => {
			await send(comp, 'allocateTo', [rho._address, mantissa(1)]);
			await expect(send(rho, '_transferComp', [a2, mantissa(1)], {from: a1})).rejects.toRevert('Must be admin to transfer comp');
			await send(rho, '_transferComp', [a2, mantissa(1)], {from: root});
			const bal = await call(comp, 'balanceOf', [a2]);
			expect(bal).toEqNum(mantissa(1));
		});

	});
});

describe('Pause Admin Tests', () => {
	// root just deploys, has no actions with protocol
	const [root, lp, a1, a2, ...accounts] = saddle.accounts;
	let cToken, rho;

	// rho and ctoken contract start with mocked bn of 100
	beforeEach(async () => {
		({ cToken, rho} = await deployProtocol({mockModel: true, liquidityLimit: bn(50e8)}));
		await prep(rho._address, bn(51e8), cToken, lp);
		await send(cToken, 'setBorrowIndex', [mantissa(1.2)]);
		await send(rho, 'supply', [bn(49.9e8)], {
			from: lp,
		});
	});

	it('should revert on supply', async () => {
		await expect(send(rho, 'supply', [bn(2e8)], {from: lp})).rejects.toRevert('Supply paused, above liquidity limit');
		
	});

	it('should revert on open', async () => {
		await prep(rho._address, mantissa(100), cToken, a1);
		await send(rho, 'openReceiveFixedSwap', [mantissa(200), bn(0)], {from: a1});// just to get over the limit
		await send(rho, 'advanceBlocks', [5000]);
		await expect(send(rho, 'openReceiveFixedSwap', [mantissa(1), bn(0)], {from: a1})).rejects.toRevert('Open paused, above liquidity limit');
	});

});
