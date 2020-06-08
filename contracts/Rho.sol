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
	uint public swapMinDuration = 345600;
	uint public maxFloatRateMantissa;
	uint public minFloatRateMantissa;

	mapping(address => SupplyAccount) public accounts;
	mapping(bytes32 => bool) public payFixedSwaps;


	event Test(uint a, uint b);
	event Accrue(uint totalLiquidityNew, uint lockedCollateralNew);

	event OpenPayFixedSwap(
		bytes32 txHash,
		uint benchmarkIndexInit,
		uint initBlock,
		uint swapFixedRateMantissa,
		uint notionalAmount,
		uint maxFloatRateMantissa,
		uint userCollateral,
		address indexed owner
	);

	struct SupplyAccount {
		uint amount;
		uint supplyBlock;
		uint supplyIndex;
	}

	struct PayFixedSwap {
		uint priorMaxFloatRateMantissa;
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
	 * receives a Compound floating rate for swapMinDuration.
	*/
	// add owner as a param?


	struct OpenPayFixedLocalVars {
		Exp avgFixedRateReceivingNew;
		uint fixedNotionalReceivingNew;
		uint fixedToReceiveNew;
		uint parBlocksPayingFloatNew;
		uint floatNotionalPayingNew;
	}

	function openPayFixedSwap(uint notionalAmount) public returns (bytes32) {
		uint lockedCollateral = accrue();
		Exp memory swapFixedRate = _newExp(interestRateModel.getRatePayFixed(notionalAmount));

		OpenPayFixedLocalVars memory vars;

		// protocol is receiving fixed, if user is paying fixed
		uint lockedCollateralHypothetical = _add(lockedCollateral, getReceiveFixedInitCollateral(swapFixedRate, notionalAmount));

		require(lockedCollateralHypothetical <= totalLiquidity, "Insufficient protocol collateral");

		vars.fixedNotionalReceivingNew = _add(fixedNotionalReceiving, notionalAmount);
		vars.floatNotionalPayingNew = _add(floatNotionalPaying, notionalAmount);

		// += notionalAmount * swapFixedRate * swapMinDuration
		vars.fixedToReceiveNew = _add(fixedToReceive, _mul(_mul(swapMinDuration, notionalAmount), swapFixedRate));
		vars.parBlocksPayingFloatNew = _add(parBlocksPayingFloat, _mul(notionalAmount, swapMinDuration));

		// = (avgFixedRateReceiving * fixedNotionalReceiving + notionalAmount * swapFixedRate) / (fixedNotionalReceiving + notionalAmount);
		Exp memory fixedReceivingPerBlock = _mul(_newExp(avgFixedRateReceivingMantissa), fixedNotionalReceiving);
		Exp memory orderFixedToReceivePerBlock = _mul(swapFixedRate, notionalAmount);
		vars.avgFixedRateReceivingNew = _div(_add(fixedReceivingPerBlock, orderFixedToReceivePerBlock), vars.fixedNotionalReceivingNew);

		uint userCollateral = getPayFixedInitCollateral(swapFixedRate, notionalAmount);

		bytes32 swapHash = keccak256(abi.encode(
			benchmarkIndexStored,
			getBlockNumber(),
			swapFixedRate.mantissa,
			notionalAmount,
			maxFloatRateMantissa,
			userCollateral,
			msg.sender
		));

		require(payFixedSwaps[swapHash] == false, "Duplicate swap");
		payFixedSwaps[swapHash] = true;

		emit OpenPayFixedSwap(
			swapHash,
			benchmarkIndexStored,
			getBlockNumber(),
			swapFixedRate.mantissa,
			notionalAmount,
			maxFloatRateMantissa,
			userCollateral,
			msg.sender
		);

		avgFixedRateReceivingMantissa = vars.avgFixedRateReceivingNew.mantissa;
		fixedNotionalReceiving = vars.fixedNotionalReceivingNew;
		fixedToReceive = vars.fixedToReceiveNew;

		parBlocksPayingFloat = vars.parBlocksPayingFloatNew;
		floatNotionalPaying = vars.floatNotionalPayingNew;

		// require true?
		underlying.transferFrom(msg.sender, address(this), userCollateral);
		return swapHash;
	}

	// function openReceiveFixedSwap(uint notionalAmount) public {
	// }

	struct ClosePayFixedLocalVars {
		uint fixedNotionalReceivingNew;
		uint fixedToReceiveNew;
		Exp avgFixedRateReceivingNew;
		uint floatNotionalPayingNew;
		uint parBlocksPayingFloatNew;
	}

	function closePayFixedSwap(
		uint benchmarkInitIndex,
		uint initBlock,
		uint swapFixedRateMantissa,
		uint priorMaxFloatRateMantissa,
		uint notionalAmount,
		uint userCollateral,
		address owner
	) public {
		// dont accrue if delta blocks == 0?
		emit Test(getBlockNumber(), initBlock);
		accrue();
		return;
		bytes32 swapHash = keccak256(abi.encode(
			benchmarkInitIndex,
			initBlock,
			swapFixedRateMantissa,
			notionalAmount,
			priorMaxFloatRateMantissa,
			userCollateral,
			owner
		));
		require(payFixedSwaps[swapHash] == true, "No active swap found");
		uint swapDuration = _sub(getBlockNumber(), initBlock);
		require(swapDuration >= swapMinDuration, "Premature close swap");
		Exp memory actualFloatRate = _div(_newExp(benchmarkIndexStored), _newExp(benchmarkInitIndex));

		ClosePayFixedLocalVars memory vars;

		/* fixedNotionalReceiving -= notionalAmount
		 * floatNotionalPaying -= notionalAmount * actualFloatRate // undo compounding
		 * avgFixedRateReceiving = avgFixedRateReceiving * fixedNotionalReceiving - swapFixedRateMantissa * notionalAmount / fixedNotionalReceivingNew
		 */

		vars.fixedNotionalReceivingNew = _sub(fixedNotionalReceiving, notionalAmount);
		vars.floatNotionalPayingNew = _sub(floatNotionalPaying, _mul(notionalAmount, actualFloatRate));

		if (vars.fixedNotionalReceivingNew != 0 ){
			Exp memory numerator = _sub(_mul(_newExp(avgFixedRateReceivingMantissa), fixedNotionalReceiving), _mul(_newExp(swapFixedRateMantissa), notionalAmount));
			vars.avgFixedRateReceivingNew = _div(numerator, vars.fixedNotionalReceivingNew);
		} else {
			vars.avgFixedRateReceivingNew = _newExp(0);
		}


		/* Late blocks adjustments. The protocol reserved enough collateral for this swap for ${swapDuration}, but its has been ${swapDuration + lateBlocks}.
		 * We have consistently decreased the lockedCollateral from the `open` fn in every `accrue`, and in fact we have decreased it by more than we ever added in the first place.
		 * 		parBlocksPayingFloat += notionalAmount * lateBlocks
		 * 		fixedToReceive += notionalAmount * lateBlocks * swapFixedRate
		 */

		uint lateBlocks = _sub(swapDuration, swapMinDuration);
		vars.fixedToReceiveNew = _add(fixedToReceive, _mul(_mul(notionalAmount, lateBlocks), _newExp(swapFixedRateMantissa)));
		vars.parBlocksPayingFloatNew = _add(parBlocksPayingFloat, _mul(notionalAmount, lateBlocks));

		/* Calculate the user's payout:
		 * 		fixedLeg = notionalAmount * swapDuration * swapFixedRate
		 * 		floatLeg = notionalAmount * min(actualFloatRate, priorMaxFloatRate)
		 * 		userPayout = userCollateral + fixedLeg - floatLeg
		 */

		uint fixedLeg = _mul(_mul(notionalAmount, swapDuration), _newExp(swapFixedRateMantissa));
		Exp memory effectiveFloatRate = _min(actualFloatRate, _newExp(priorMaxFloatRateMantissa));
		uint floatLeg = _mul(notionalAmount, effectiveFloatRate);
		uint userPayout = _sub(_add(userCollateral, floatLeg), fixedLeg);


		// Apply effects and interactions

		payFixedSwaps[swapHash] = false;
		fixedNotionalReceiving = vars.fixedNotionalReceivingNew;
		fixedToReceive = vars.fixedToReceiveNew;
		avgFixedRateReceivingMantissa = vars.avgFixedRateReceivingNew.mantissa;
		floatNotionalPaying = vars.floatNotionalPayingNew;
		parBlocksPayingFloat = vars.parBlocksPayingFloatNew;

		underlying.transfer(owner, userPayout);
	}

	struct AccrueLocalVars {
		uint totalLiquidityNew;
		uint supplyIndexNew;
		Exp benchmarkIndexNew;
	}


	 // function accrueApply() public returns {
	 // 	uint lockedCollat, int editable ...,  = accrue();
	 // 	editable = uint(editable)
	 // 	apply
	 // }

	// function accrueClosePayFixed() public returns {
	//  	uint lockedCollat, int editable ...,  = accrue();
	//  	retur neditable4
	//  	applySome
	//  	return some.



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
		 * 		fixedToReceive -= accruedBlocks * fixedNotionalReceiving * avgFixedRateReceiving
		 */

		uint fixedReceived = _mul(accruedBlocks, _mul(fixedNotionalReceiving, _newExp(avgFixedRateReceivingMantissa)));
		uint fixedToReceiveNew = _sub(fixedToReceive, fixedReceived);

		uint fixedPaid = _mul(accruedBlocks, _mul(fixedNotionalPaying, _newExp(avgFixedRatePayingMantissa)));
		uint fixedToPayNew = _sub(fixedToPay, fixedPaid);


		/*  CALCULATE PROTOCOL P/L
		 * 		totalLiquidity += fixedReceived + floatReceived - fixedPaid - floatPaid
		 * 		supplyIndex *= totalLiquidityNew / totalLiquidity
		 */

		lockedCollateralNew = getLockedCollateral(
			parBlocksPayingFloatNew,
			parBlocksReceivingFloatNew,
			minFloatRateMantissa,
			maxFloatRateMantissa,
			fixedToPayNew,
			fixedToReceiveNew
		);
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
	 *  = notionalAmount * swapMinDuration * (swapFixedRate - minFloatRate)
	 */
	function getPayFixedInitCollateral(Exp memory fixedRate, uint notionalAmount) public view returns (uint) {
		Exp memory rateDelta = _sub(fixedRate, _newExp(minFloatRateMantissa));
		return _mul(_mul(swapMinDuration, notionalAmount), rateDelta);
	}

	/* The amount that must be locked up for the leg of a swap receiving fixed
	 * = notionalAmount * swapMinDuration * (maxFloatRate - swapFixedRate)
	 */
	function getReceiveFixedInitCollateral(Exp memory fixedRate, uint notionalAmount) public view returns (uint) {
		Exp memory rateDelta = _sub(_newExp(maxFloatRateMantissa), fixedRate);
		return _mul(_mul(swapMinDuration, notionalAmount), rateDelta);
	}

	function getBlockNumber() public view returns (uint) {
		return block.number;
	}

	function getBenchmarkIndex() public view returns (uint) {
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
