pragma experimental ABIEncoderV2;
pragma solidity ^0.6.10;

import "./IERC20.sol";
import "./SafeMath.sol";
import "./InterestRateModel.sol";
import "./Math.sol";

interface BenchmarkInterface {
	function getBorrowIndex() external view returns (uint);
}

abstract contract CTokenInterface is IERC20 {
	function exchangeRateStored() external view virtual returns (uint);
}

contract Rho is Math {

	InterestRateModelInterface public interestRateModel;
	CTokenInterface public immutable cTokenCollateral;
	BenchmarkInterface public benchmark;// TODO: find a way to make this immutable

	uint public immutable swapMinDuration;
	uint public immutable supplyMinDuration;

	uint public lastAccrualBlock;
	uint public benchmarkIndexStored;

	/* notional size of each leg, one adjusting for compounding and one static */
	uint public notionalReceivingFixed;
	uint public notionalPayingFloat;

	uint public notionalPayingFixed;
	uint public notionalReceivingFloat;

	/* Measure of outstanding swap obligations. 1 Unit = 1e18 notional * 1 block. Used to calculate collateral requirements */
	int public parBlocksReceivingFixed;
	int public parBlocksPayingFixed;

	/* Fixed / float interest rates used in collateral calculations */
	uint public avgFixedRateReceivingMantissa;
	uint public avgFixedRatePayingMantissa;

	/* Float rate bounds used in collateral calculations */
	uint public maxFloatRateMantissa;
	uint public minFloatRateMantissa;

	/* Protocol PnL */
	uint public supplyIndex;
	CTokenAmount public supplierLiquidity;

	mapping(address => SupplyAccount) public supplyAccounts;
	mapping(bytes32 => bool) public swaps;

	event Test(uint a, uint b, uint c);
	event Accrue(CTokenAmount supplierLiquidityNew, uint lockedCollateralNew);

	event OpenSwap(
		bytes32 txHash,
		bool userPayingFixed,
		uint benchmarkIndexInit,
		uint initBlock,
		uint swapFixedRateMantissa,
		uint notionalAmount,
		uint userCollateralCTokens,
		address indexed owner
	);


	struct SupplyAccount {
		//TODO be consistent, either store all as structs or none
		CTokenAmount amount;
		uint lastBlock;
		uint index;
	}

	struct Swap {
		bool userPayingFixed;
		uint notionalAmount;
		uint swapFixedRateMantissa;
		uint benchmarkIndexInit;
		uint userCollateralCTokens;
		uint initBlock;
		address owner;
	}

	constructor (
		InterestRateModelInterface interestRateModel_,
		BenchmarkInterface benchmark_,
		CTokenInterface cTokenCollateral_,
		uint minFloatRateMantissa_,
		uint maxFloatRateMantissa_,
		uint swapMinDuration_,
		uint supplyMinDuration_
	) public {
		interestRateModel = interestRateModel_;
		benchmark = benchmark_;
		cTokenCollateral = cTokenCollateral_;
		minFloatRateMantissa = minFloatRateMantissa_;
		maxFloatRateMantissa = maxFloatRateMantissa_;
		swapMinDuration = swapMinDuration_;
		supplyMinDuration = supplyMinDuration_;

		supplyIndex = _oneExp().mantissa;

		benchmarkIndexStored = getBenchmarkIndex();
	}

	function supplyLiquidity(uint cTokenSupplyAmount) public {
		CTokenAmount memory supplyAmount = CTokenAmount({val: cTokenSupplyAmount});
		accrue();
		uint prevIndex = supplyAccounts[msg.sender].index;
		CTokenAmount memory prevSupply = supplyAccounts[msg.sender].amount;

		CTokenAmount memory truedUpPrevSupply;

		if (prevSupply.val == 0) {
			truedUpPrevSupply = CTokenAmount({val: 0});
		} else {
			truedUpPrevSupply = _div(_mul(prevSupply, supplyIndex), prevIndex);
		}

		supplyAccounts[msg.sender].amount = _add(truedUpPrevSupply, supplyAmount);
		supplyAccounts[msg.sender].lastBlock = getBlockNumber();
		supplyAccounts[msg.sender].index = supplyIndex;

		supplierLiquidity = _add(supplierLiquidity, supplyAmount);

		transferIn(msg.sender, supplyAmount);
	}

	function removeLiquidity(uint removeCTokenAmount) public {
		CTokenAmount memory removeAmount = CTokenAmount({val: removeCTokenAmount});
		SupplyAccount memory account = supplyAccounts[msg.sender];
		require(account.amount.val > 0, "Must withdraw from active account");
		require(getBlockNumber() - account.lastBlock >= supplyMinDuration, "Liquidity must be supplied a minimum duration");

		CTokenAmount memory lockedCollateral = accrue();
		CTokenAmount memory truedUpAccountValue = _div(_mul(account.amount, supplyIndex), account.index);

		// Remove all liquidity
		if (removeAmount.val == uint(-1)) {
			removeAmount = truedUpAccountValue;
		}

		require(_lte(removeAmount, truedUpAccountValue), "Trying to remove more than account value");
		CTokenAmount memory unlockedCollateral = _sub(supplierLiquidity, lockedCollateral);
		require(_lte(removeAmount, unlockedCollateral), "Removing more liquidity than is unlocked");
		require(_lte(removeAmount, supplierLiquidity), "Removing more than total supplier liquidity");

		CTokenAmount memory newAccountValue = _sub(truedUpAccountValue, removeAmount);

		supplyAccounts[msg.sender].lastBlock = getBlockNumber();
		supplyAccounts[msg.sender].index = supplyIndex;
		supplyAccounts[msg.sender].amount = newAccountValue;

		supplierLiquidity = _sub(supplierLiquidity, removeAmount);

		transferOut(msg.sender, removeAmount);
	}

	/* Opens a swap where the user pays the protocol-offered fixed rate and
	 * receives a Compound floating rate for swapMinDuration.
	*/

	function open(bool userPayingFixed, uint notionalAmount) public returns (bytes32 swapHash) {
		CTokenAmount memory lockedCollateral = accrue();
		Exp memory swapFixedRate = getRate(userPayingFixed, notionalAmount);

		CTokenAmount memory userCollateralCTokens;
		if (userPayingFixed) {
			CTokenAmount memory lockedCollateralHypothetical = _add(lockedCollateral, getReceiveFixedInitCollateral(swapFixedRate, notionalAmount));
			require(_lte(lockedCollateralHypothetical, supplierLiquidity), "Insufficient protocol collateral");
			(swapHash, userCollateralCTokens) = openPayFixedSwapInternal(notionalAmount, swapFixedRate);
		} else {
			// TODO:
			require(false, "Error");
		}
		swaps[swapHash] = true;
		transferIn(msg.sender, userCollateralCTokens);
	}


	/* protocol is receiving fixed, if user is paying fixed */
	function openPayFixedSwapInternal(uint notionalAmount, Exp memory swapFixedRate) internal returns (bytes32 swapHash, CTokenAmount memory userCollateralCTokens) {
		uint notionalReceivingFixedNew = _add(notionalReceivingFixed, notionalAmount);
		uint notionalPayingFloatNew = _add(notionalPayingFloat, notionalAmount);

		int parBlocksReceivingFixedNew = _add(parBlocksReceivingFixed, _mul(swapMinDuration, notionalAmount));

		/* avgFixedRateReceivingNew = (avgFixedRateReceiving * notionalReceivingFixed + notionalAmount * swapFixedRate) / (notionalReceivingFixed + notionalAmount);*/
		Exp memory avgFixedRateReceivingNew;
		{
			Exp memory priorFixedReceivingRate= _mul(_exp(avgFixedRateReceivingMantissa), notionalReceivingFixed);
			Exp memory orderFixedReceivingRate = _mul(swapFixedRate, notionalAmount);
			avgFixedRateReceivingNew = _div(_add(priorFixedReceivingRate, orderFixedReceivingRate), notionalReceivingFixedNew);
		}

		userCollateralCTokens = getPayFixedInitCollateral(swapFixedRate, notionalAmount);

		swapHash = keccak256(abi.encode(
			true,				    // userPayingFixed
			benchmarkIndexStored,
			getBlockNumber(),
			swapFixedRate.mantissa,
			notionalAmount,
			userCollateralCTokens.val,
			msg.sender
		));

		require(swaps[swapHash] == false, "Duplicate swap");

		emit OpenSwap(
			swapHash,
			true, 					// userPayingFixed
			benchmarkIndexStored,
			getBlockNumber(),
			swapFixedRate.mantissa,
			notionalAmount,
			userCollateralCTokens.val,
			msg.sender
		);

		notionalPayingFloat = notionalPayingFloatNew;
		notionalReceivingFixed = notionalReceivingFixedNew;
		avgFixedRateReceivingMantissa = avgFixedRateReceivingNew.mantissa;
		parBlocksReceivingFixed = parBlocksReceivingFixedNew;

		return (swapHash, userCollateralCTokens);
	}

	// function openReceiveFixedSwap(uint notionalAmount) public {}

	function close(
		bool userPayingFixed,
		uint benchmarkInitIndex,
		uint initBlock,
		uint swapFixedRateMantissa,
		uint notionalAmount,
		uint userCollateralCTokens,
		address owner
	) public {
		accrue();
		bytes32 swapHash = keccak256(abi.encode(
			userPayingFixed,
			benchmarkInitIndex,
			initBlock,
			swapFixedRateMantissa,
			notionalAmount,
			userCollateralCTokens,
			owner
		));

		uint swapDuration = _sub(getBlockNumber(), initBlock);
		require(swapDuration >= swapMinDuration, "Premature close swap");
		require(swaps[swapHash] == true, "No active swap found");
		Exp memory floatRate = _div(_exp(benchmarkIndexStored), _exp(benchmarkInitIndex));

		CTokenAmount memory userPayout;
		if (userPayingFixed == true) {
			userPayout = closePayFixedSwapInternal(
				swapDuration,
				floatRate,
				swapFixedRateMantissa,
				notionalAmount,
				CTokenAmount({val: userCollateralCTokens})
			);
		} else {
			//todo
			require(false, 'TODO');
		}
		// TODO: emit event
		swaps[swapHash] = false;
		transferOut(owner, userPayout);
	}

	function closePayFixedSwapInternal(
		uint swapDuration,
		Exp memory floatRate,
		uint swapFixedRateMantissa,
		uint notionalAmount,
		CTokenAmount memory userCollateral
	) internal returns (CTokenAmount memory userPayout) {
		uint notionalReceivingFixedNew = _sub(notionalReceivingFixed, notionalAmount);
		uint notionalPayingFloatNew = _sub(notionalPayingFloat, _mul(notionalAmount, floatRate));

		/* avgFixedRateReceiving = avgFixedRateReceiving * notionalReceivingFixed - swapFixedRateMantissa * notionalAmount / notionalReceivingFixedNew */
		Exp memory avgFixedRateReceivingNew;
		if (notionalReceivingFixedNew == 0 ){
			avgFixedRateReceivingNew = _exp(0);
		} else {
			Exp memory numerator = _sub(_mul(_exp(avgFixedRateReceivingMantissa), notionalReceivingFixed), _mul(_exp(swapFixedRateMantissa), notionalAmount));
			avgFixedRateReceivingNew = _div(numerator, notionalReceivingFixedNew);
		}

		/* Late blocks adjustments. The protocol reserved enough collateral for this swap for ${swapDuration}, but its has been ${swapDuration + lateBlocks}.
		 * We have consistently decreased the lockedCollateral from the `open` fn in every `accrue`, and in fact we have decreased it by more than we ever added in the first place.
		 */

		uint lateBlocks = _sub(swapDuration, swapMinDuration);
		int parBlocksReceivingFixedNew = _add(parBlocksReceivingFixed, _mul(notionalAmount, lateBlocks));

		/* Calculate the user's payout:
		 * 		fixedLeg = notionalAmount * swapDuration * swapFixedRate
		 * 		floatLeg = notionalAmount * (floatRate - 1)
		 * 		userPayout = userCollateral + floatLeg - fixedLeg
		 */

		CTokenAmount memory fixedLeg = toCTokens(_mul(_mul(notionalAmount, swapDuration), _exp(swapFixedRateMantissa)));
		CTokenAmount memory floatLeg = toCTokens(_mul(notionalAmount,_sub(floatRate, _oneExp())));
		userPayout = _sub(_add(userCollateral, floatLeg), fixedLeg);

		notionalReceivingFixed = notionalReceivingFixedNew;
		notionalPayingFloat = notionalPayingFloatNew;
		parBlocksReceivingFixed = parBlocksReceivingFixedNew;
		avgFixedRateReceivingMantissa = avgFixedRateReceivingNew.mantissa;

		return userPayout;
	}

	function accrue() internal returns (CTokenAmount memory lockedCollateralNew) {
		uint accruedBlocks = getBlockNumber() - lastAccrualBlock;

		int parBlocksReceivingFixedNew;
		int parBlocksPayingFixedNew;
		(lockedCollateralNew, parBlocksReceivingFixedNew, parBlocksPayingFixedNew) = getLockedCollateralInternal(accruedBlocks);

		if (accruedBlocks == 0) {
			return lockedCollateralNew;
		}

		Exp memory benchmarkIndexNew = _exp(getBenchmarkIndex());
		Exp memory benchmarkIndexRatio = _div(benchmarkIndexNew, _exp(benchmarkIndexStored));
		require(benchmarkIndexRatio.mantissa >= _oneExp().mantissa, "Decreasing float rate");

		/*  Calculate protocol P/L by adding the cashflows since last accrual
		 * 		supplierLiquidity += fixedReceived + floatReceived - fixedPaid - floatPaid
		 * 		supplyIndex *= supplierLiquidityNew / supplierLiquidity
		 */
		CTokenAmount memory supplierLiquidityNew;
		{
			uint floatPaid = _mul(notionalPayingFloat, _sub(benchmarkIndexRatio, _oneExp()));
			uint floatReceived = _mul(notionalReceivingFloat, _sub(benchmarkIndexRatio, _oneExp()));
			uint fixedPaid = _mul(accruedBlocks, _mul(notionalPayingFixed, _exp(avgFixedRatePayingMantissa)));
			uint fixedReceived = _mul(accruedBlocks, _mul(notionalReceivingFixed, _exp(avgFixedRateReceivingMantissa)));
			// XXX: safely handle supplierLiquidity going negative?
			supplierLiquidityNew = _sub(_add(supplierLiquidity, toCTokens(_add(fixedReceived, floatReceived))), toCTokens(_add(fixedPaid, floatPaid)));
		}

		uint supplyIndexNew = supplyIndex;
		if (supplierLiquidityNew.val != 0) {
			supplyIndexNew = _div(_mul(supplyIndex, supplierLiquidityNew), supplierLiquidity);
		}

		/*  Compound float notional */
		uint notionalPayingFloatNew = _mul(notionalPayingFloat, benchmarkIndexRatio);
		uint notionalReceivingFloatNew = _mul(notionalReceivingFloat, benchmarkIndexRatio);

		// ** APPLY EFFECTS **

		parBlocksPayingFixed = parBlocksPayingFixedNew;
		parBlocksReceivingFixed = parBlocksReceivingFixedNew;

		supplierLiquidity = supplierLiquidityNew;
		supplyIndex = supplyIndexNew;

		notionalPayingFloat = notionalPayingFloatNew;
		notionalReceivingFloat = notionalReceivingFloatNew;

		benchmarkIndexStored = benchmarkIndexNew.mantissa;
		lastAccrualBlock = getBlockNumber();

		emit Accrue(supplierLiquidityNew, lockedCollateralNew.val);
		return lockedCollateralNew;
	}

	function getLockedCollateralInternal(uint accruedBlocks) internal view returns (CTokenAmount memory lockedCollateral, int parBlocksReceivingFixedNew, int parBlocksPayingFixedNew) {
		/* Calculate protocol fixed rate credit/debt. Use int to keep negatives, for correct late blocks calc when a single swap is outstanding */
		parBlocksReceivingFixedNew = _sub(parBlocksReceivingFixed, _mul(accruedBlocks, notionalReceivingFixed));
		parBlocksPayingFixedNew = _sub(parBlocksPayingFixed, _mul(accruedBlocks, notionalPayingFixed));

		uint minFloatToReceive = _mul(_toUint(parBlocksPayingFixedNew), _exp(minFloatRateMantissa));
		uint maxFloatToPay = _mul(_toUint(parBlocksReceivingFixedNew), _exp(maxFloatRateMantissa));

		uint fixedToReceive = _mul(_toUint(parBlocksReceivingFixedNew), _exp(avgFixedRateReceivingMantissa));
		uint fixedToPay = _mul(_toUint(parBlocksPayingFixedNew), _exp(avgFixedRatePayingMantissa));

		uint minCredit = _add(fixedToReceive, minFloatToReceive);
		uint maxDebt = _add(fixedToPay, maxFloatToPay);

		if (maxDebt > minCredit) {
			lockedCollateral = toCTokens(_sub(maxDebt, minCredit));
		} else {
			lockedCollateral = CTokenAmount({val:0});
		}
	}

	/*  The amount that must be locked up for the leg of a swap paying fixed
	 *  = notionalAmount * swapMinDuration * (swapFixedRate - minFloatRate)
	 */
	function getPayFixedInitCollateral(Exp memory fixedRate, uint notionalAmount) public returns (CTokenAmount memory) {
		Exp memory rateDelta = _sub(fixedRate, _exp(minFloatRateMantissa));
		emit Test(swapMinDuration, notionalAmount, rateDelta.mantissa);
		return toCTokens(_mul(_mul(swapMinDuration, notionalAmount), rateDelta));
	}

	/* The amount that must be locked up for the leg of a swap receiving fixed
	 * = notionalAmount * swapMinDuration * (maxFloatRate - swapFixedRate)
	 */
	function getReceiveFixedInitCollateral(Exp memory fixedRate, uint notionalAmount) public view returns (CTokenAmount memory) {
		Exp memory rateDelta = _sub(_exp(maxFloatRateMantissa), fixedRate);
		return toCTokens(_mul(_mul(swapMinDuration, notionalAmount), rateDelta));
	}

	// TODO: gas optimize, accept exchange rate as param
	function toCTokens(uint amt) public view returns (CTokenAmount memory) {
		uint cTokenAmount = _div(amt, _exp(cTokenCollateral.exchangeRateStored()));
		return CTokenAmount({val: cTokenAmount});
	}

	function toUnderlying(CTokenAmount memory amt) public view returns (uint) {
		return _mul(amt.val, _exp(cTokenCollateral.exchangeRateStored()));
	}

	// TODO: Add more validation?
	function transferIn(address from, CTokenAmount memory cTokenAmount) internal {
		cTokenCollateral.transferFrom(from, address(this), cTokenAmount.val);
	}

	function transferOut(address to, CTokenAmount memory cTokenAmount) internal {
		cTokenCollateral.transfer(to, cTokenAmount.val);
	}

	function getBenchmarkIndex() public view returns (uint) {
		uint idx = benchmark.getBorrowIndex();
		require(idx != 0, "Benchmark index is zero");
		return idx;
	}

	function getRate(bool userPayingFixed, uint notionalAmount) internal view returns (Exp memory rate) {
		return _exp(interestRateModel.getRate(userPayingFixed, notionalAmount));
	}

	function getBlockNumber() public view virtual returns (uint) {
		return block.number;
	}


	function getLockedCollateral() external view returns (CTokenAmount memory lockedCollateral) {
		uint accruedBlocks = getBlockNumber() - lastAccrualBlock;
		(lockedCollateral,,) = getLockedCollateralInternal(accruedBlocks);
	}


	// ** ADMIN FUNCTIONS **

	// function _setInterestRateModel() {}

	// function _setCollateralRequirements(uint minFloatRateMantissa_, uint maxFloatRateMantissa_){}

	// function _setMaxLiquidity() {}

	// function pause() {}

	// function renounceAdmin() {}

	// function transferComp() {}

}
