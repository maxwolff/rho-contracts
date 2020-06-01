pragma experimental ABIEncoderV2;
pragma solidity ^0.5.12;

import "./IERC20.sol";
import "./SafeMath.sol";
import "./InterestRateModel.sol";
import "./Math.sol";

contract BenchmarkInterface {
	uint public borrowIndex;
}

contract Rho is Math {

	InterestRateModelInterface public interestRateModel;
	IERC20 public underlying;
	BenchmarkInterface public benchmark;

	uint public benchmarkIndexStored;
	uint public lastAccrualBlock;

	// ** Fixed rate accounting **
	uint public fixedNotionalReceiving;
	uint public fixedNotionalPaying;

	uint public fixedToReceive;
	uint public fixedToPay;

	uint public avgFixedRateReceivingMantissa;
	uint public avgFixedRatePayingMantissa;

	// ** Float rate accounting **
	uint public floatNotionalPaying;
	uint public floatNotionalReceiving;

	uint public parBlocksReceivingFloat;
	uint public parBlocksPayingFloat;

	// ** Protocol accounting **
	uint public supplyIndex;
	uint public totalLiquidity;

	//XXX decide for sure. 60 days in blocks, assuming 15s blocks
	uint public swapDuration = 345600;
	uint public maxFloatRateMantissa;
	uint public minFloatRateMantissa;

	mapping(address => SupplyAccount) public accounts;
	mapping(bytes32 => bool) public payFixedSwaps;


	event Test(uint a, uint b);
	event Accrue(uint totalLiquidityNew, uint lockedCollateralNew);
	event OpenPayFixedSwap(/*bytes32 txHash,*/ address indexed owner, uint userCollateral, uint notionalAmount, uint swapFixedRateMantissa, uint benchmarkIndexInit, uint maxFloatRateMantissa, uint initBlock);

	struct SupplyAccount {
		uint amount;
		uint supplyBlock;
		uint supplyIndex;
	}

	struct PayFixedSwap {
		uint maxFloatRateMantissa;
		uint notionalAmount;
		uint swapFixedRateMantissa;
		uint benchmarkIndexInit;
		uint userCollateral;
		uint initBlock;
		address owner;
	}

	constructor (InterestRateModelInterface interestRateModel_, BenchmarkInterface benchmark_, IERC20 underlying_, uint minFloatRateMantissa_, uint maxFloatRateMantissa_) public {
		interestRateModel = interestRateModel_;
		benchmark = benchmark_;
		underlying = underlying_;
		minFloatRateMantissa = minFloatRateMantissa_;
		maxFloatRateMantissa = maxFloatRateMantissa_;

		supplyIndex = EXP_SCALE;

		benchmarkIndexStored = getBenchmarkIndex();
	}

	function supplyLiquidity(uint supplyAmount) public {
		accrue();
		SupplyAccount storage account = accounts[msg.sender];

		uint truedUpLiquidity = 0;
		if (account.amount != 0 && account.supplyIndex != 0) {
			truedUpLiquidity = _div(_mul(account.amount, supplyIndex), account.supplyIndex);
		}

		account.amount = _add(truedUpLiquidity, supplyAmount);
		account.supplyBlock = getBlockNumber();
		account.supplyIndex = supplyIndex;

		totalLiquidity = _add(totalLiquidity, supplyAmount);

		underlying.transferFrom(msg.sender, address(this), supplyAmount);
	}

	// function removeLiquidity(uint withdrawAmount) public {

	// }

	/* Opens a swap where the user pays the protocol-offered fixed rate and
	 * receives a Compound floating rate for swapDuration.
	*/

	event openPayFixedSwapEvent(address owner, uint userCollateral, uint notionalAmount, uint swapFixedRateMantissa, uint benchmarkIndexInit, uint maxFloatRateMantissa, uint initBlock);
	function openPayFixedSwap(uint notionalAmount) public {
		uint lockedCollateral = accrue();
		Exp memory swapFixedRate = _newExp(interestRateModel.getRatePayFixed(notionalAmount));

		// protocol is receiving fixed, if user is paying fixed
		uint lockedCollateralHypothetical = _add(lockedCollateral, getReceiveFixedInitCollateral(swapFixedRate, notionalAmount));

		require(lockedCollateralHypothetical <= totalLiquidity, "Insufficient protocol collateral");

		uint fixedNotionalReceivingNew = _add(fixedNotionalReceiving, notionalAmount);
		uint floatNotionalPayingNew = _add(floatNotionalPaying, notionalAmount);

		// += notionalAmount * swapFixedRate * swapDuration
		uint fixedToReceiveNew = _add(fixedToReceive, _mul(_mul(swapDuration, notionalAmount), swapFixedRate));
		uint parBlocksPayingFloatNew = _add(parBlocksPayingFloat, _mul(notionalAmount, swapDuration));

		// = (avgFixedRateReceiving * fixedNotionalReceiving + notionalAmount * swapFixedRate) / (fixedNotionalReceiving + notionalAmount);
		Exp memory fixedReceivingPerBlock = _mul(_newExp(avgFixedRateReceivingMantissa), fixedNotionalReceiving);
		Exp memory orderFixedToReceivePerBlock = _mul(swapFixedRate, notionalAmount);
		Exp memory avgFixedRateReceivingNew = _div(_add(fixedReceivingPerBlock, orderFixedToReceivePerBlock), fixedNotionalReceivingNew);

		uint userCollateral = getPayFixedInitCollateral(swapFixedRate, notionalAmount);

		bytes32 swapHash = keccak256(abi.encode(
			msg.sender,
			userCollateral,
			notionalAmount,
			swapFixedRate.mantissa,
			benchmarkIndexStored,
			maxFloatRateMantissa,
			getBlockNumber())
		);

		payFixedSwaps[swapHash] = true;

		emit OpenPayFixedSwap(
			// swapHash,
			msg.sender,
			userCollateral,
			notionalAmount,
			swapFixedRate.mantissa,
			benchmarkIndexStored,//redundant sload
			maxFloatRateMantissa,
			getBlockNumber()
		);

		avgFixedRateReceivingMantissa = avgFixedRateReceivingNew.mantissa;
		fixedNotionalReceiving = fixedNotionalReceivingNew;
		fixedToReceive = fixedToReceiveNew;

		parBlocksPayingFloat = parBlocksPayingFloatNew;
		floatNotionalPaying = floatNotionalPayingNew;

		// require true?
		underlying.transferFrom(msg.sender, address(this), userCollateral);
	}

	// function openReceiveFixedSwap(uint notionalAmount) public {
	// 	uint lockedCollateral = accrue();
	// 	Exp memory swapFixedRate = _newExp(interestRateModel.getRateReceiveFixed(notionalAmount));

	// 	// protocol is paying fixed, user is receiving fixed
	// 	uint lockedCollateralHypothetical = _add(lockedCollateral, getPayFixedInitCollateral(swapFixedRate, notionalAmount));

	// 	require(lockedCollateralHypothetical <= totalLiquidity, "Insufficient protocol liquidity");

	// 	uint
	// }

	// function closeSwap(uint orderNumber) public {

	// }

	struct AccrueLocalVars {
		uint totalLiquidityNew;
		uint supplyIndexNew;
		Exp benchmarkIndexNew;
	}

	function accrue() internal returns (uint lockedCollateralNew) {
		AccrueLocalVars memory vars;
		uint accruedBlocks = getBlockNumber() - lastAccrualBlock;

		vars.benchmarkIndexNew = _newExp(getBenchmarkIndex());
		Exp memory benchmarkIndexRatio = _div(vars.benchmarkIndexNew, _newExp(benchmarkIndexStored));
		require(benchmarkIndexRatio.mantissa >= _scaleToExp(1).mantissa, "Decreasing float rate");

		/* CALCULATE PROTOCOL FLOAT RATE CREDIT/DEBT
		 * 		floatPaid = floatNotionalPaying * (benchmarkIndexRatio - 1)
		 * 		floatReceived = floatNotionalReceiving  * (benchmarkIndexRatio - 1)
		 * 		parBlocksReceivingFloat += fixedNotionalPaying * accruedBlocks
		 * 		parBlocksPayingFloat += fixedNotionalReceiving * accruedBlocks
		 * 		floatNotionalPaying *= benchmarkIndexRatio
		 * 		floatNotionalReceiving *= benchmarkIndexRatio
		 */

		uint floatPaid = _mul(floatNotionalPaying, _sub(benchmarkIndexRatio, _scaleToExp(1)));
		uint floatReceived = _mul(floatNotionalReceiving, _sub(benchmarkIndexRatio, _scaleToExp(1)));

		uint parBlocksReceivingFloatNew = _sub(parBlocksReceivingFloat, _mul(fixedNotionalPaying, accruedBlocks));
		uint parBlocksPayingFloatNew = _sub(parBlocksPayingFloat, _mul(fixedNotionalReceiving, accruedBlocks));

		uint floatNotionalPayingNew = _mul(floatNotionalPaying, benchmarkIndexRatio);
		uint floatNotionalReceivingNew = _mul(floatNotionalReceiving, benchmarkIndexRatio);

		/* CALCULATE  PROTOCOL FIXED RATE CREDIT/DEBT
		 *		fixedReceived = accruedBlocks * fixedNotionalReceiving * avgFixedRateReceiving
		 * 		fixedToReceiveNew -= fixedReceived
		 */

		uint fixedReceived = _mul(accruedBlocks, _mul(fixedNotionalReceiving, _newExp(avgFixedRateReceivingMantissa)));
		uint fixedToReceiveNew = _sub(fixedToReceive, fixedReceived);

		uint fixedPaid = _mul(accruedBlocks, _mul(fixedNotionalPaying, _newExp(avgFixedRatePayingMantissa)));
		uint fixedToPayNew = _sub(fixedToPay, fixedPaid);

		lockedCollateralNew = getLockedCollateral(
			parBlocksPayingFloatNew,
			parBlocksReceivingFloatNew,
			minFloatRateMantissa,
			maxFloatRateMantissa,
			fixedToPayNew,
			fixedToReceiveNew
		);

		/*  CALCULATE PROTOCOL P/L
		 * 		totalLiquidity += fixedReceived + floatReceived - fixedPaid - floatPaid
		 * 		supplyIndex *= totalLiquidityNew / totalLiquidity
		 */

		// Short circuit if none of the values changed and need to be re-saved
		if (accruedBlocks == 0) {
			return lockedCollateralNew;
		}

		// XXX: safely handle totalLiquidity going negative?
		vars.totalLiquidityNew = _sub(_add(totalLiquidity, _add(fixedReceived, floatReceived)), _add(fixedPaid, floatPaid));

		vars.supplyIndexNew = supplyIndex;
		if (vars.totalLiquidityNew != 0) {
			vars.supplyIndexNew = _div(_mul(supplyIndex, vars.totalLiquidityNew), totalLiquidity);
		}

		// ** APPLY EFFECTS **

		floatNotionalPaying = floatNotionalPayingNew;
		floatNotionalReceiving = floatNotionalReceivingNew;
		parBlocksPayingFloat = parBlocksPayingFloatNew;
		parBlocksReceivingFloat = parBlocksReceivingFloatNew;

		fixedToPay = fixedToPayNew;
		fixedToReceive = fixedToReceiveNew;

		totalLiquidity = vars.totalLiquidityNew;
		supplyIndex = vars.supplyIndexNew;

		benchmarkIndexStored = vars.benchmarkIndexNew.mantissa;
		lastAccrualBlock = getBlockNumber();
		emit Accrue(vars.totalLiquidityNew, lockedCollateralNew);
		return lockedCollateralNew;
	}

	function getLockedCollateral(
		uint parBlocksPayingFloatNew,
		uint parBlocksReceivingFloatNew,
		uint minFloatRateMantissa_,
		uint maxFloatRateMantissa_,
		uint fixedToPayNew,
		uint fixedToReceiveNew
	) public pure returns (uint lockedCollateralNew) {
		uint minFloatToReceive = _mul(parBlocksReceivingFloatNew, _newExp(minFloatRateMantissa_));
		uint maxFloatToPay = _mul(parBlocksPayingFloatNew, _newExp(maxFloatRateMantissa_));

		uint minCredit = _add(fixedToReceiveNew, minFloatToReceive);
		uint maxDebt = _add(fixedToPayNew, maxFloatToPay);

		if (minCredit < maxDebt) {
			return _sub(maxDebt, minCredit);
		} else {
			return 0;
		}
	}

	/*  The amount that must be locked up for the leg of a swap paying fixed
	 *  = notionalAmount * swapDuration * (swapFixedRate - minFloatRate)
	 */
	function getPayFixedInitCollateral(Exp memory fixedRate, uint notionalAmount) public view returns (uint) {
		Exp memory rateDelta = _sub(fixedRate, _newExp(minFloatRateMantissa));
		return _mul(_mul(swapDuration, notionalAmount), rateDelta);
	}

	/* The amount that must be locked up for the leg of a swap receiving fixed
	 * = notionalAmount * swapDuration * (maxFloatRate - swapFixedRate)
	 */
	function getReceiveFixedInitCollateral(Exp memory fixedRate, uint notionalAmount) public returns (uint) {
		Exp memory rateDelta = _sub(_newExp(maxFloatRateMantissa), fixedRate);
		return _mul(_mul(swapDuration, notionalAmount), rateDelta);
	}

	function getBlockNumber() public returns (uint) {
		return block.number;
	}

	function getBenchmarkIndex() public returns (uint) {
		uint idx = benchmark.borrowIndex();
		require(idx != 0, "Benchmark index is zero");
		return idx;
	}

	// ** ADMIN FUNCTIONS **

	// function _setInterestRateModel() {}

	// function _setCollateralRequirements(uint minFloatRateMantissa_, uint maxFloatRateMantissa_){}

	// function pause() {}

	// function renounceAdmin() {}

	// function transferComp() {}

}
