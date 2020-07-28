// SPDX-License-Identifier: GPL-3.0
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
	IERC20 public comp;
	BenchmarkInterface public benchmark;// TODO: find a way to make this immutable

	uint public immutable swapMinDuration;
	uint public immutable supplyMinDuration;

	uint public lastAccrualBlock;
	uint public benchmarkIndexStored;

	/* Notional size of each leg, one adjusting for compounding and one static */
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

	int public rateFactor;// for interest rate model

	address public admin;
	bool public isPaused;

	mapping(address => SupplyAccount) public supplyAccounts;
	mapping(bytes32 => bool) public swaps;

	event Supply(address supplier, uint cTokenSupplyAmount, uint newSupplyAmount);
	event Remove(address supplier, uint removeCTokenAmount, uint newSupplyValue);

	event OpenSwap(
		bytes32 indexed txHash,
		bool userPayingFixed,
		uint benchmarkIndexInit,
		uint initBlock,
		uint swapFixedRateMantissa,
		uint notionalAmount,
		uint userCollateralCTokens,
		address indexed owner
	);

	event CloseSwap(
		bytes32 indexed swapHash,
		address indexed owner,
		uint userPayout,
		uint benchmarkIndexStored
	);

	event Accrue(uint supplierLiquidityNew, uint lockedCollateralNew);// necessary?

	event SetInterestRateModel(address newModel, address oldModel);
	event SetPause(bool isPaused);
	event AdminRenounced();
	event CompTransferred(address dest, uint amount);

	struct SupplyAccount {
		//TODO: be consistent, either store mantissas as structs or dont store this one as struct either
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
		IERC20 comp_,
		uint minFloatRateMantissa_,
		uint maxFloatRateMantissa_,
		uint swapMinDuration_,
		uint supplyMinDuration_,
		address admin_
	) public {
		interestRateModel = interestRateModel_;
		benchmark = benchmark_;
		cTokenCollateral = cTokenCollateral_;
		comp = comp_;
		minFloatRateMantissa = minFloatRateMantissa_;
		maxFloatRateMantissa = maxFloatRateMantissa_;
		swapMinDuration = swapMinDuration_;
		supplyMinDuration = supplyMinDuration_;
		admin = admin_;

		supplyIndex = _oneExp().mantissa;
		benchmarkIndexStored = getBenchmarkIndex();
		isPaused = false;
	}

	/* @dev Supplies liquidity to the protcol
	 * @param cTokenSupplyAmount Amount to supply, in CTokens.
	 */
	function supply(uint cTokenSupplyAmount) public {
		require(isPaused == false, "Market paused");
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

		CTokenAmount memory newSupplyAmount = _add(truedUpPrevSupply, supplyAmount);

		emit Supply(msg.sender, cTokenSupplyAmount, newSupplyAmount.val);

		supplyAccounts[msg.sender].amount = newSupplyAmount;
		supplyAccounts[msg.sender].lastBlock = getBlockNumber();
		supplyAccounts[msg.sender].index = supplyIndex;

		supplierLiquidity = _add(supplierLiquidity, supplyAmount);

		transferIn(msg.sender, supplyAmount);
	}

	/* @dev Removes liquidity from protocol. Can only perform after a waiting period from supplying, to prevent interest rate manipulation
	 * @param removeCTokenAmount Amount of CTokens to remove. -1 removes all CTokens.
	 */
	function remove(uint removeCTokenAmount) public {
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

		emit Remove(msg.sender, removeCTokenAmount, newAccountValue.val);

		supplyAccounts[msg.sender].lastBlock = getBlockNumber();
		supplyAccounts[msg.sender].index = supplyIndex;
		supplyAccounts[msg.sender].amount = newAccountValue;

		supplierLiquidity = _sub(supplierLiquidity, removeAmount);

		transferOut(msg.sender, removeAmount);
	}

	/* @dev Opens a new interest rate swap
	 * @param userPayingFixed : The user can choose if they want to receive fixed or pay fixed (the protocol will take the opposite side)
	 * @param notionalAmount : The principal that interest rate payments will be based on
	*/
	function open(bool userPayingFixed, uint notionalAmount) public returns (bytes32 swapHash) {
		require(isPaused == false, "Market paused");
		CTokenAmount memory lockedCollateral = accrue();
		Exp memory swapFixedRate = getSwapRate(userPayingFixed, notionalAmount, lockedCollateral.val, supplierLiquidity.val);

		CTokenAmount memory userCollateralCTokens;
		if (userPayingFixed) {
			CTokenAmount memory lockedCollateralHypothetical = _add(lockedCollateral, getReceiveFixedInitCollateral(swapFixedRate, notionalAmount));
			require(_lte(lockedCollateralHypothetical, supplierLiquidity), "Insufficient protocol collateral");
			userCollateralCTokens = openPayFixedSwapInternal(notionalAmount, swapFixedRate);
		} else {
			CTokenAmount memory lockedCollateralHypothetical = _add(lockedCollateral, getPayFixedInitCollateral(swapFixedRate, notionalAmount));
			require(_lte(lockedCollateralHypothetical, supplierLiquidity), "Insufficient protocol collateral");
			userCollateralCTokens = openReceiveFixedSwapInternal(notionalAmount, swapFixedRate);
		}

		swapHash = keccak256(abi.encode(
			userPayingFixed,
			benchmarkIndexStored,
			getBlockNumber(),
			swapFixedRate.mantissa,
			notionalAmount,
			userCollateralCTokens.val,
			msg.sender
		));

		require(swaps[swapHash] == false, "Duplicate swap");// TODO possibly move, checks effects & interactions

		emit OpenSwap(
			swapHash,
			userPayingFixed,
			benchmarkIndexStored,
			getBlockNumber(),
			swapFixedRate.mantissa,
			notionalAmount,
			userCollateralCTokens.val,
			msg.sender
		);

		swaps[swapHash] = true;
		transferIn(msg.sender, userCollateralCTokens);
	}


	// @dev User is paying fixed, protocol is receiving fixed
	function openPayFixedSwapInternal(uint notionalAmount, Exp memory swapFixedRate) internal returns (CTokenAmount memory userCollateralCTokens) {
		uint notionalReceivingFixedNew = _add(notionalReceivingFixed, notionalAmount);
		uint notionalPayingFloatNew = _add(notionalPayingFloat, notionalAmount);

		int parBlocksReceivingFixedNew = _add(parBlocksReceivingFixed, _mul(swapMinDuration, notionalAmount));

		/* avgFixedRateReceivingNew = (avgFixedRateReceiving * notionalReceivingFixed + notionalAmount * swapFixedRate) / (notionalReceivingFixed + notionalAmount);*/
		Exp memory priorFixedReceivingRate = _mul(_exp(avgFixedRateReceivingMantissa), notionalReceivingFixed);
		Exp memory orderFixedReceivingRate = _mul(swapFixedRate, notionalAmount);
		Exp memory avgFixedRateReceivingNew = _div(_add(priorFixedReceivingRate, orderFixedReceivingRate), notionalReceivingFixedNew);

		userCollateralCTokens = getPayFixedInitCollateral(swapFixedRate, notionalAmount);

		notionalPayingFloat = notionalPayingFloatNew;
		notionalReceivingFixed = notionalReceivingFixedNew;
		avgFixedRateReceivingMantissa = avgFixedRateReceivingNew.mantissa;
		parBlocksReceivingFixed = parBlocksReceivingFixedNew;

		return userCollateralCTokens;
	}

	// @dev User is receiving fixed, protocol is paying fixed
	function openReceiveFixedSwapInternal(uint notionalAmount, Exp memory swapFixedRate) internal returns (CTokenAmount memory userCollateralCTokens) {
		uint notionalPayingFixedNew = _add(notionalPayingFixed, notionalAmount);
		uint notionalReceivingFloatNew = _add(notionalReceivingFloat, notionalAmount);

		int parBlocksPayingFixedNew = _add(parBlocksPayingFixed, _mul(swapMinDuration, notionalAmount));

		/* avgFixedRatePayingNew = (avgFixedRatePaying * notionalPayingFixed + notionalAmount * swapFixedRate) / (notionalPayingFixed + notionalAmount) */
		Exp memory priorFixedPayingRate = _mul(_exp(avgFixedRatePayingMantissa), notionalPayingFixed);
		Exp memory orderFixedPayingRate = _mul(swapFixedRate, notionalAmount);
		Exp memory avgFixedRatePayingNew = _div(_add(priorFixedPayingRate, orderFixedPayingRate), notionalPayingFixedNew);

		userCollateralCTokens = getReceiveFixedInitCollateral(swapFixedRate, notionalAmount);

		notionalReceivingFloat = notionalReceivingFloatNew;
		notionalPayingFixed = notionalPayingFixedNew;
		avgFixedRatePayingMantissa = avgFixedRatePayingNew.mantissa;
		parBlocksPayingFixed = parBlocksPayingFixedNew;

		return userCollateralCTokens;
	}

	// @dev Closes a swap, takes params from Open event. Must be past the min swap duration. Float payment continues even if closed late.
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
		Exp memory benchmarkIndexRatio = _div(_exp(benchmarkIndexStored), _exp(benchmarkInitIndex));

		CTokenAmount memory userCollateral = CTokenAmount({val: userCollateralCTokens});
		Exp memory swapFixedRate = _exp(swapFixedRateMantissa);

		CTokenAmount memory userPayout;
		if (userPayingFixed) {
			userPayout = closePayFixedSwapInternal(
				swapDuration,
				benchmarkIndexRatio,
				swapFixedRate,
				notionalAmount,
				userCollateral
			);
		} else {
			userPayout = closeReceiveFixedSwapInternal(
				swapDuration,
				benchmarkIndexRatio,
				swapFixedRate,
				notionalAmount,
				userCollateral
			);
		}
		emit CloseSwap(swapHash, owner, userPayout.val, benchmarkIndexStored);
		swaps[swapHash] = false;
		transferOut(owner, userPayout);
	}

	// @dev User paid fixed, protocol paid fixed
	function closePayFixedSwapInternal(
		uint swapDuration,
		Exp memory benchmarkIndexRatio,
		Exp memory swapFixedRate,
		uint notionalAmount,
		CTokenAmount memory userCollateral
	) internal returns (CTokenAmount memory userPayout) {
		uint notionalReceivingFixedNew = _sub(notionalReceivingFixed, notionalAmount);
		uint notionalPayingFloatNew = _sub(notionalPayingFloat, _mul(notionalAmount, benchmarkIndexRatio));

		/* avgFixedRateReceiving = avgFixedRateReceiving * notionalReceivingFixed - swapFixedRateMantissa * notionalAmount / notionalReceivingFixedNew */
		Exp memory avgFixedRateReceivingNew;
		if (notionalReceivingFixedNew == 0){
			avgFixedRateReceivingNew = _exp(0);
		} else {
			Exp memory numerator = _sub(_mul(_exp(avgFixedRateReceivingMantissa), notionalReceivingFixed), _mul(swapFixedRate, notionalAmount));
			avgFixedRateReceivingNew = _div(numerator, notionalReceivingFixedNew);
		}

		/* The protocol reserved enough collateral for this swap for SWAP_MIN_DURATION, but its has been longer.
		 * We have decreased lockedCollateral in `accrue` for the late blocks, meaning we decreased it by more than the "open" tx added to it in the first place.
		 */

		uint lateBlocks = _sub(swapDuration, swapMinDuration);
		int parBlocksReceivingFixedNew = _add(parBlocksReceivingFixed, _mul(notionalAmount, lateBlocks));

		CTokenAmount memory fixedLeg = toCTokens(_mul(_mul(notionalAmount, swapDuration), swapFixedRate));
		CTokenAmount memory floatLeg = toCTokens(_mul(notionalAmount, _sub(benchmarkIndexRatio, _oneExp())));
		userPayout = _sub(_add(userCollateral, floatLeg), fixedLeg);

		notionalReceivingFixed = notionalReceivingFixedNew;
		notionalPayingFloat = notionalPayingFloatNew;
		parBlocksReceivingFixed = parBlocksReceivingFixedNew;
		avgFixedRateReceivingMantissa = avgFixedRateReceivingNew.mantissa;

		return userPayout;
	}

	// @dev User received fixed, protocol paid fixed
	function closeReceiveFixedSwapInternal(
		uint swapDuration,
		Exp memory benchmarkIndexRatio,
		Exp memory swapFixedRate,
		uint notionalAmount,
		CTokenAmount memory userCollateral
	) internal returns (CTokenAmount memory userPayout) {
		uint notionalPayingFixedNew = _sub(notionalPayingFixed, notionalAmount);
		uint notionalReceivingFloatNew = _sub(notionalReceivingFloat, _mul(notionalAmount, benchmarkIndexRatio));

		/* avgFixedRatePaying = avgFixedRatePaying * notionalPayingFixed - swapFixedRateMantissa * notionalAmount / notionalReceivingFixedNew */
		Exp memory avgFixedRatePayingNew;
		if (notionalPayingFixedNew == 0) {
			avgFixedRatePayingNew = _exp(0);
		} else {
			Exp memory numerator = _sub(_mul(_exp(avgFixedRatePayingMantissa), notionalPayingFixed), _mul(swapFixedRate, notionalAmount));
			avgFixedRatePayingNew = _div(numerator, notionalReceivingFloatNew);
		}

		/* The protocol reserved enough collateral for this swap for SWAP_MIN_DURATION, but its has been longer.
		 * We have decreased lockedCollateral in `accrue` for the late blocks, meaning we decreased it by more than the "open" tx added to it in the first place.
		 */
		uint lateBlocks = _sub(swapDuration, swapMinDuration);
		int parBlocksPayingFixedNew = _add(parBlocksPayingFixed, _mul(notionalAmount, lateBlocks));

		CTokenAmount memory fixedLeg = toCTokens(_mul(_mul(notionalAmount, swapDuration), swapFixedRate));
		CTokenAmount memory floatLeg = toCTokens(_mul(notionalAmount, _sub(benchmarkIndexRatio, _oneExp())));
		userPayout = _sub(_add(userCollateral, fixedLeg), floatLeg);

		notionalPayingFixed = notionalPayingFixedNew;
		notionalReceivingFloat = notionalReceivingFloatNew;
		parBlocksPayingFixed = parBlocksPayingFixedNew;
		avgFixedRatePayingMantissa = avgFixedRatePayingNew.mantissa;

		return userPayout;
	}

	// @dev Apply interest rate payments and adjust collateral requirements as time passes.
	// @return lockedCollateralNew : The amount of collateral the protocol needs to keep locked.
	function accrue() internal returns (CTokenAmount memory) {
		uint accruedBlocks = getBlockNumber() - lastAccrualBlock;

		(CTokenAmount memory lockedCollateralNew, int parBlocksReceivingFixedNew, int parBlocksPayingFixedNew) = getLockedCollateralInternal(accruedBlocks);

		if (accruedBlocks == 0) {
			return lockedCollateralNew;
		}

		uint benchmarkIndexNew = getBenchmarkIndex();
		Exp memory benchmarkIndexRatio = _div(_exp(benchmarkIndexNew), _exp(benchmarkIndexStored));
		Exp memory floatRate = _sub(benchmarkIndexRatio, _oneExp());

		CTokenAmount memory supplierLiquidityNew = getSupplierLiquidityInternal(accruedBlocks, floatRate);

		uint supplyIndexNew = supplyIndex;
		if (supplierLiquidityNew.val != 0) {
			supplyIndexNew = _div(_mul(supplyIndex, supplierLiquidityNew), supplierLiquidity);
		}

		uint notionalPayingFloatNew = _mul(notionalPayingFloat, benchmarkIndexRatio);
		uint notionalReceivingFloatNew = _mul(notionalReceivingFloat, benchmarkIndexRatio);

		/** Apply Effects **/

		parBlocksPayingFixed = parBlocksPayingFixedNew;
		parBlocksReceivingFixed = parBlocksReceivingFixedNew;

		supplierLiquidity = supplierLiquidityNew;
		supplyIndex = supplyIndexNew;

		notionalPayingFloat = notionalPayingFloatNew;
		notionalReceivingFloat = notionalReceivingFloatNew;

		benchmarkIndexStored = benchmarkIndexNew;
		lastAccrualBlock = getBlockNumber();

		emit Accrue(supplierLiquidityNew.val, lockedCollateralNew.val);
		return lockedCollateralNew;
	}

	/* @dev Calculate protocol P/L by adding the cashflows since last accrual.
	 * 		supplierLiquidity += fixedReceived + floatReceived - fixedPaid - floatPaid
	 * 		supplyIndex *= supplierLiquidityNew / supplierLiquidity
	 */
	function getSupplierLiquidityInternal(uint accruedBlocks, Exp memory floatRate) internal view returns (CTokenAmount memory supplierLiquidityNew) {
		uint floatPaid = _mul(notionalPayingFloat, floatRate);
		uint floatReceived = _mul(notionalReceivingFloat, floatRate);
		uint fixedPaid = _mul(accruedBlocks, _mul(notionalPayingFixed, _exp(avgFixedRatePayingMantissa)));
		uint fixedReceived = _mul(accruedBlocks, _mul(notionalReceivingFixed, _exp(avgFixedRateReceivingMantissa)));
		// TODO: safely handle supplierLiquidity going negative?
		supplierLiquidityNew = _sub(_add(supplierLiquidity, toCTokens(_add(fixedReceived, floatReceived))), toCTokens(_add(fixedPaid, floatPaid)));
	}

	// @dev Calculate protocol locked collateral and parBlocks, which is a measure of the fixed rate credit/debt.
	// * Use int to keep negatives, for correct late blocks calc when a single swap is outstanding
	function getLockedCollateralInternal(uint accruedBlocks) internal view returns (CTokenAmount memory lockedCollateral, int parBlocksReceivingFixedNew, int parBlocksPayingFixedNew) {
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

	// * TODO: gas optimize, accept exchange rate as param
	function toCTokens(uint amt) public view returns (CTokenAmount memory) {
		uint cTokenAmount = _div(amt, _exp(cTokenCollateral.exchangeRateStored()));
		return CTokenAmount({val: cTokenAmount});
	}

	function toUnderlying(CTokenAmount memory amt) public view returns (uint) {
		return _mul(amt.val, _exp(cTokenCollateral.exchangeRateStored()));
	}

	function transferIn(address from, CTokenAmount memory cTokenAmount) internal {
		// TODO: Add more validation?
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

	// @dev Get the rate for incoming swaps
	function getSwapRate(bool userPayingFixed, uint orderNotional, uint lockedCollateralUnderlying, uint supplierLiquidityUnderlying) internal returns (Exp memory) {
		(uint rate, int rateFactorNew) = interestRateModel.getSwapRate(rateFactor, userPayingFixed, orderNotional, lockedCollateralUnderlying, supplierLiquidityUnderlying);
		rateFactor = rateFactorNew;
		return _exp(rate);
	}

	// @dev The amount that must be locked up for the leg of a swap paying fixed
	// *  = notionalAmount * swapMinDuration * (swapFixedRate - minFloatRate)
	function getPayFixedInitCollateral(Exp memory fixedRate, uint notionalAmount) public view returns (CTokenAmount memory) {
		Exp memory rateDelta = _sub(fixedRate, _exp(minFloatRateMantissa));
		return toCTokens(_mul(_mul(swapMinDuration, notionalAmount), rateDelta));
	}

	// @dev The amount that must be locked up for the leg of a swap receiving fixed
	// = notionalAmount * swapMinDuration * (maxFloatRate - swapFixedRate)
	function getReceiveFixedInitCollateral(Exp memory fixedRate, uint notionalAmount) public view returns (CTokenAmount memory) {
		Exp memory rateDelta = _sub(_exp(maxFloatRateMantissa), fixedRate);
		return toCTokens(_mul(_mul(swapMinDuration, notionalAmount), rateDelta));
	}

	function getSupplyCollateralState() external view returns (CTokenAmount memory lockedCollateral, CTokenAmount memory unlockedCollateral) {
		uint accruedBlocks = getBlockNumber() - lastAccrualBlock;
		Exp memory benchmarkIndexRatio = _div(_exp(getBenchmarkIndex()), _exp(benchmarkIndexStored));
		Exp memory floatRate = _sub(benchmarkIndexRatio, _oneExp());

		(lockedCollateral,,) = getLockedCollateralInternal(accruedBlocks);
		CTokenAmount memory supplierLiquidityNew = getSupplierLiquidityInternal(accruedBlocks, floatRate);
		unlockedCollateral = _sub(supplierLiquidityNew, lockedCollateral);
	}

	function getBlockNumber() public view virtual returns (uint) {
		return block.number;
	}

	/** ADMIN FUNCTIONS **/

	function _setInterestRateModel(InterestRateModel newModel) external {
		require(msg.sender == admin, "Must be admin to set interest rate model");
		require(newModel != interestRateModel, "Resetting to same model");
		emit SetInterestRateModel(address(newModel), address(interestRateModel));
		interestRateModel = newModel;
	}

	function _setPause(bool isPaused_) external {
		require(msg.sender == admin, "Must be admin to pause");
		require(isPaused_ != isPaused, "Must change isPaused");
		emit SetPause(isPaused_);
		isPaused = isPaused_;
	}

	function _renounceAdmin() external {
		require(msg.sender == admin, "Must be admin to renounce admin");
		emit AdminRenounced();
		admin = address(0);
	}

	function _transferComp(address dest, uint amount) external {
		require(msg.sender == admin, "Must be admin to transfer comp");
		emit CompTransferred(dest, amount);
		comp.transfer(dest, amount);
	}

	// TODO? function _setMaxSupplierLiquidity(uint ) {}

}
