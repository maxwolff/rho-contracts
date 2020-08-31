// SPDX-License-Identifier: GPL-3.0
pragma experimental ABIEncoderV2;
pragma solidity ^0.6.10;

import "./InterestRateModel.sol";
import "./Math.sol";

interface CompInterface {
    function transfer(address to, uint256 value) external returns (bool);
}

interface CTokenInterface {
	function transferFrom(address from, address to, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);

	function borrowIndex() external view returns (uint);
	function accrualBlockNumber() external view returns(uint);
	function borrowRatePerBlock() external view returns(uint);
	function exchangeRateStored() external view returns (uint);
}

interface RhoInterface {
	function supply(uint cTokenSupplyAmount) external;
	function remove(uint removeCTokenAmount) external;
	function open(bool userPayingFixed, uint notionalAmount, uint fixedRateLimitMantissa) external returns (bytes32 swapHash);
	function close(
		bool userPayingFixed,
		uint benchmarkInitIndex,
		uint initBlock,
		uint swapFixedRateMantissa,
		uint notionalAmount,
		uint userCollateralCTokens,
		address owner
	) external;
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
		uint benchmarkIndexInit,
		uint benchmarkIndexStored
	);
	event Accrue(uint supplierLiquidityNew, uint lockedCollateralNew);
	event SetInterestRateModel(address newModel, address oldModel);
	event SetPause(bool isPaused);
	event AdminRenounced();
	event CompTransferred(address dest, uint amount);
	event SetCollateralRequirements(uint minFloatRateMantissa, uint maxFloatRateMantissa);
	event AdminChanged(address oldAdmin, address newAdmin);
}

/* Notes:
 * CTokens are used as collateral. "Underlying" in Rho refers to the collateral CToken's underlying token.
 * An Exp is a data type with 18 decimals, used for scaling up and precise calculations.
*/

contract Rho is RhoInterface, Math {

	InterestRateModelInterface public interestRateModel;
	CTokenInterface public immutable cToken;
	CompInterface public immutable comp;

	uint public immutable SWAP_MIN_DURATION;
	uint public immutable SUPPLY_MIN_DURATION;

	uint public lastAccrualBlock;
	Exp public benchmarkIndexStored;

	/* Notional size of each leg, one adjusting for compounding and one static */
	uint public notionalReceivingFixed;
	uint public notionalPayingFloat;

	uint public notionalPayingFixed;
	uint public notionalReceivingFloat;

	/* Measure of outstanding swap obligations. 1 Unit = 1e18 notional * 1 block. Used to calculate collateral requirements */
	int public parBlocksReceivingFixed;
	int public parBlocksPayingFixed;

	/* Per block fixed / float interest rates used in collateral calculations */
	Exp public avgFixedRateReceiving;
	Exp public avgFixedRatePaying;

	/* Per block float rate bounds used in collateral calculations */
	Exp public maxFloatRate;
	Exp public minFloatRate;

	/* Protocol PnL */
	uint public supplyIndex;
	CTokenAmount public supplierLiquidity;

	int public rateFactor;// for interest rate model

	address public admin;
	bool public isPaused;

	mapping(address => SupplyAccount) public supplyAccounts;
	mapping(bytes32 => bool) public swaps;

	struct SupplyAccount {
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
		CTokenInterface cToken_,
		CompInterface comp_,
		uint minFloatRateMantissa_,
		uint maxFloatRateMantissa_,
		uint swapMinDuration_,
		uint supplyMinDuration_,
		address admin_
	) public {
		require(minFloatRateMantissa_ < maxFloatRateMantissa_, "Min float rate must be below max float rate");
		require(minFloatRateMantissa_ < 1e11, "Min float rate above maximum");
		require(maxFloatRateMantissa_ > 1e10, "Max float rate below minimum");

		interestRateModel = interestRateModel_;
		cToken = cToken_;
		comp = comp_;
		minFloatRate = _exp(minFloatRateMantissa_);
		maxFloatRate = _exp(maxFloatRateMantissa_);
		SWAP_MIN_DURATION = swapMinDuration_;
		SUPPLY_MIN_DURATION = supplyMinDuration_;
		admin = admin_;

		supplyIndex = ONE_EXP.mantissa;
		benchmarkIndexStored = _exp(cToken_.borrowIndex());
		isPaused = false;
	}

	/* @dev Supplies liquidity to the protocol. Become the counterparty for all swap traders, in return for fees.
	 * @param cTokenSupplyAmount Amount to supply, in CTokens.
	 */
	function supply(uint cTokenSupplyAmount) public override {
		require(isPaused == false, "Market paused");
		CTokenAmount memory supplyAmount = CTokenAmount({val: cTokenSupplyAmount});

		Exp memory cTokenExchangeRate = getExchangeRate();
		accrue(cTokenExchangeRate);
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

	/* @dev Remove liquidity from protocol. Can only perform after a waiting period from supplying, to prevent interest rate manipulation
	 * @param removeCTokenAmount Amount of CTokens to remove. 0 removes all CTokens.
	 */
	function remove(uint removeCTokenAmount) public override {
		CTokenAmount memory removeAmount = CTokenAmount({val: removeCTokenAmount});
		SupplyAccount memory account = supplyAccounts[msg.sender];
		require(account.amount.val > 0, "Must withdraw from active account");
		require(getBlockNumber() - account.lastBlock >= SUPPLY_MIN_DURATION, "Liquidity must be supplied a minimum duration");

		Exp memory cTokenExchangeRate = getExchangeRate();
		CTokenAmount memory lockedCollateral = accrue(cTokenExchangeRate);
		CTokenAmount memory truedUpAccountValue = _div(_mul(account.amount, supplyIndex), account.index);

		// Remove all liquidity
		if (removeAmount.val == 0) {
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
	 * @param fixedRateLimitMantissa : The maximum (if payingFixed) or minimum (if receivingFixed) rate the swap should succeed at. Prevents frontrunning attacks.
	 	* The amount of interest to pay over 2,102,400 blocks (~1 year), with 18 decimals of precision. Eg: 5% per block-year => 0.5e18.
	*/
	function open(bool userPayingFixed, uint notionalAmount, uint fixedRateLimitMantissa) public override returns (bytes32 swapHash) {
		require(isPaused == false, "Market paused");
		require(notionalAmount >= 1e18, "Swap notional amount must exceed minimum");
		Exp memory cTokenExchangeRate = getExchangeRate();
		CTokenAmount memory lockedCollateral = accrue(cTokenExchangeRate);
		(Exp memory swapFixedRate, int rateFactorNew) = getSwapRate(userPayingFixed, notionalAmount, lockedCollateral, supplierLiquidity, cTokenExchangeRate);
		CTokenAmount memory userCollateralCTokens;
		if (userPayingFixed) {
			require(swapFixedRate.mantissa <= fixedRateLimitMantissa, "The fixed rate Rho would receive is above user's limit");
			CTokenAmount memory lockedCollateralHypothetical = _add(lockedCollateral, getReceiveFixedInitCollateral(swapFixedRate, notionalAmount, cTokenExchangeRate));
			require(_lte(lockedCollateralHypothetical, supplierLiquidity), "Insufficient protocol collateral");
			userCollateralCTokens = openPayFixedSwapInternal(notionalAmount, swapFixedRate, cTokenExchangeRate);
		} else {
			require(swapFixedRate.mantissa >= fixedRateLimitMantissa, "The fixed rate Rho would pay is below user's limit");
			CTokenAmount memory lockedCollateralHypothetical = _add(lockedCollateral, getPayFixedInitCollateral(swapFixedRate, notionalAmount, cTokenExchangeRate));
			require(_lte(lockedCollateralHypothetical, supplierLiquidity), "Insufficient protocol collateral");
			userCollateralCTokens = openReceiveFixedSwapInternal(notionalAmount, swapFixedRate, cTokenExchangeRate);
		}

		swapHash = keccak256(abi.encode(
			userPayingFixed,
			benchmarkIndexStored.mantissa,
			getBlockNumber(),
			swapFixedRate.mantissa,
			notionalAmount,
			userCollateralCTokens.val,
			msg.sender
		));

		require(swaps[swapHash] == false, "Duplicate swap");

		emit OpenSwap(
			swapHash,
			userPayingFixed,
			benchmarkIndexStored.mantissa,
			getBlockNumber(),
			swapFixedRate.mantissa,
			notionalAmount,
			userCollateralCTokens.val,
			msg.sender
		);

		swaps[swapHash] = true;
		rateFactor = rateFactorNew;
		transferIn(msg.sender, userCollateralCTokens);
	}


	// @dev User is paying fixed, protocol is receiving fixed
	function openPayFixedSwapInternal(uint notionalAmount, Exp memory swapFixedRate, Exp memory cTokenExchangeRate) internal returns (CTokenAmount memory userCollateralCTokens) {
		uint notionalReceivingFixedNew = _add(notionalReceivingFixed, notionalAmount);
		uint notionalPayingFloatNew = _add(notionalPayingFloat, notionalAmount);

		int parBlocksReceivingFixedNew = _add(parBlocksReceivingFixed, _mul(SWAP_MIN_DURATION, notionalAmount));

		/* avgFixedRateReceivingNew = (avgFixedRateReceiving * notionalReceivingFixed + notionalAmount * swapFixedRate) / (notionalReceivingFixed + notionalAmount);*/
		Exp memory priorFixedReceivingRate = _mul(avgFixedRateReceiving, notionalReceivingFixed);
		Exp memory orderFixedReceivingRate = _mul(swapFixedRate, notionalAmount);
		Exp memory avgFixedRateReceivingNew = _div(_add(priorFixedReceivingRate, orderFixedReceivingRate), notionalReceivingFixedNew);

		userCollateralCTokens = getPayFixedInitCollateral(swapFixedRate, notionalAmount, cTokenExchangeRate);

		notionalPayingFloat = notionalPayingFloatNew;
		notionalReceivingFixed = notionalReceivingFixedNew;
		avgFixedRateReceiving = avgFixedRateReceivingNew;
		parBlocksReceivingFixed = parBlocksReceivingFixedNew;

		return userCollateralCTokens;
	}

	// @dev User is receiving fixed, protocol is paying fixed
	function openReceiveFixedSwapInternal(uint notionalAmount, Exp memory swapFixedRate, Exp memory cTokenExchangeRate) internal returns (CTokenAmount memory userCollateralCTokens) {
		uint notionalPayingFixedNew = _add(notionalPayingFixed, notionalAmount);
		uint notionalReceivingFloatNew = _add(notionalReceivingFloat, notionalAmount);

		int parBlocksPayingFixedNew = _add(parBlocksPayingFixed, _mul(SWAP_MIN_DURATION, notionalAmount));

		/* avgFixedRatePayingNew = (avgFixedRatePaying * notionalPayingFixed + notionalAmount * swapFixedRate) / (notionalPayingFixed + notionalAmount) */
		Exp memory priorFixedPayingRate = _mul(avgFixedRatePaying, notionalPayingFixed);
		Exp memory orderFixedPayingRate = _mul(swapFixedRate, notionalAmount);
		Exp memory avgFixedRatePayingNew = _div(_add(priorFixedPayingRate, orderFixedPayingRate), notionalPayingFixedNew);

		userCollateralCTokens = getReceiveFixedInitCollateral(swapFixedRate, notionalAmount, cTokenExchangeRate);

		notionalReceivingFloat = notionalReceivingFloatNew;
		notionalPayingFixed = notionalPayingFixedNew;
		avgFixedRatePaying = avgFixedRatePayingNew;
		parBlocksPayingFixed = parBlocksPayingFixedNew;

		return userCollateralCTokens;
	}

	/* @dev Closes an existing swap, after the min swap duration. Float payment continues even if closed late.
	 * Takes params from Open event.
	 */
	function close(
		bool userPayingFixed,
		uint benchmarkInitIndex,
		uint initBlock,
		uint swapFixedRateMantissa,
		uint notionalAmount,
		uint userCollateralCTokens,
		address owner
	) public override {
		Exp memory cTokenExchangeRate = getExchangeRate();
		accrue(cTokenExchangeRate);
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
		require(swapDuration >= SWAP_MIN_DURATION, "Premature close swap");
		require(swaps[swapHash] == true, "No active swap found");
		Exp memory benchmarkIndexRatio = _div(benchmarkIndexStored, _exp(benchmarkInitIndex));

		CTokenAmount memory userCollateral = CTokenAmount({val: userCollateralCTokens});
		Exp memory swapFixedRate = _exp(swapFixedRateMantissa);

		CTokenAmount memory userPayout;
		if (userPayingFixed) {
			userPayout = closePayFixedSwapInternal(
				swapDuration,
				benchmarkIndexRatio,
				swapFixedRate,
				notionalAmount,
				userCollateral,
				cTokenExchangeRate
			);
		} else {
			userPayout = closeReceiveFixedSwapInternal(
				swapDuration,
				benchmarkIndexRatio,
				swapFixedRate,
				notionalAmount,
				userCollateral,
				cTokenExchangeRate
			);
		}
		emit CloseSwap(swapHash, owner, userPayout.val, benchmarkIndexStored.mantissa, benchmarkIndexStored.mantissa);
		swaps[swapHash] = false;
		transferOut(owner, userPayout);
	}

	// @dev User paid fixed, protocol paid fixed
	function closePayFixedSwapInternal(
		uint swapDuration,
		Exp memory benchmarkIndexRatio,
		Exp memory swapFixedRate,
		uint notionalAmount,
		CTokenAmount memory userCollateral,
		Exp memory cTokenExchangeRate
	) internal returns (CTokenAmount memory userPayout) {
		uint notionalReceivingFixedNew = _sub(notionalReceivingFixed, notionalAmount);
		uint notionalPayingFloatNew = _sub(notionalPayingFloat, _mul(notionalAmount, benchmarkIndexRatio));

		/* avgFixedRateReceiving = avgFixedRateReceiving * notionalReceivingFixed - swapFixedRate * notionalAmount / notionalReceivingFixedNew */
		Exp memory avgFixedRateReceivingNew;
		if (notionalReceivingFixedNew == 0){
			avgFixedRateReceivingNew = _exp(0);
		} else {
			Exp memory numerator = _sub(_mul(avgFixedRateReceiving, notionalReceivingFixed), _mul(swapFixedRate, notionalAmount));
			avgFixedRateReceivingNew = _div(numerator, notionalReceivingFixedNew);
		}

		/* The protocol reserved enough collateral for this swap for SWAP_MIN_DURATION, but its has been longer.
		 * We have decreased lockedCollateral in `accrue` for the late blocks, meaning we decreased it by more than the "open" tx added to it in the first place.
		 */
		int parBlocksReceivingFixedNew = _add(parBlocksReceivingFixed, _mul(notionalAmount, _sub(swapDuration, SWAP_MIN_DURATION)));

		CTokenAmount memory fixedLeg = toCTokens(_mul(_mul(notionalAmount, swapDuration), swapFixedRate), cTokenExchangeRate);
		CTokenAmount memory floatLeg = toCTokens(_mul(notionalAmount, _sub(benchmarkIndexRatio, ONE_EXP)), cTokenExchangeRate);
		userPayout = _sub(_add(userCollateral, floatLeg), fixedLeg);

		notionalReceivingFixed = notionalReceivingFixedNew;
		notionalPayingFloat = notionalPayingFloatNew;
		parBlocksReceivingFixed = parBlocksReceivingFixedNew;
		avgFixedRateReceiving = avgFixedRateReceivingNew;

		return userPayout;
	}

	// @dev User received fixed, protocol paid fixed
	function closeReceiveFixedSwapInternal(
		uint swapDuration,
		Exp memory benchmarkIndexRatio,
		Exp memory swapFixedRate,
		uint notionalAmount,
		CTokenAmount memory userCollateral,
		Exp memory cTokenExchangeRate
	) internal returns (CTokenAmount memory userPayout) {
		uint notionalPayingFixedNew = _sub(notionalPayingFixed, notionalAmount);
		uint notionalReceivingFloatNew = _sub(notionalReceivingFloat, _mul(notionalAmount, benchmarkIndexRatio));

		/* avgFixedRatePaying = avgFixedRatePaying * notionalPayingFixed - swapFixedRate * notionalAmount / notionalReceivingFixedNew */
		Exp memory avgFixedRatePayingNew;
		if (notionalPayingFixedNew == 0) {
			avgFixedRatePayingNew = _exp(0);
		} else {
			Exp memory numerator = _sub(_mul(avgFixedRatePaying, notionalPayingFixed), _mul(swapFixedRate, notionalAmount));
			avgFixedRatePayingNew = _div(numerator, notionalReceivingFloatNew);
		}

		/* The protocol reserved enough collateral for this swap for SWAP_MIN_DURATION, but its has been longer.
		 * We have decreased lockedCollateral in `accrue` for the late blocks, meaning we decreased it by more than the "open" tx added to it in the first place.
		 */
		int parBlocksPayingFixedNew = _add(parBlocksPayingFixed, _mul(notionalAmount, _sub(swapDuration, SWAP_MIN_DURATION)));

		CTokenAmount memory fixedLeg = toCTokens(_mul(_mul(notionalAmount, swapDuration), swapFixedRate), cTokenExchangeRate);
		CTokenAmount memory floatLeg = toCTokens(_mul(notionalAmount, _sub(benchmarkIndexRatio, ONE_EXP)), cTokenExchangeRate);
		userPayout = _sub(_add(userCollateral, fixedLeg), floatLeg);

		notionalPayingFixed = notionalPayingFixedNew;
		notionalReceivingFloat = notionalReceivingFloatNew;
		parBlocksPayingFixed = parBlocksPayingFixedNew;
		avgFixedRatePaying = avgFixedRatePayingNew;

		return userPayout;
	}

	/* @dev Called internally at the beginning of external swap and liquidity provider functions.
	 * Accounts for interest rate payments and adjust collateral requirements with the passage of time.
	 * @return lockedCollateralNew : The amount of collateral the protocol needs to keep locked.
	 */
	function accrue(Exp memory cTokenExchangeRate) internal returns (CTokenAmount memory) {
		uint accruedBlocks = getBlockNumber() - lastAccrualBlock;
		(CTokenAmount memory lockedCollateralNew, int parBlocksReceivingFixedNew, int parBlocksPayingFixedNew) = getLockedCollateral(accruedBlocks, cTokenExchangeRate);

		if (accruedBlocks == 0) {
			return lockedCollateralNew;
		}

		Exp memory benchmarkIndexNew = getBenchmarkIndex();
		Exp memory benchmarkIndexRatio = _div(benchmarkIndexNew, benchmarkIndexStored);
		Exp memory floatRate = _sub(benchmarkIndexRatio, ONE_EXP);

		CTokenAmount memory supplierLiquidityNew = getSupplierLiquidity(accruedBlocks, floatRate, cTokenExchangeRate);

		// supplyIndex *= supplierLiquidityNew / supplierLiquidity
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

	function transferIn(address from, CTokenAmount memory cTokenAmount) internal {
		// TODO: Add more validation?
		cToken.transferFrom(from, address(this), cTokenAmount.val);
	}

	function transferOut(address to, CTokenAmount memory cTokenAmount) internal {
		cToken.transfer(to, cTokenAmount.val);
	}

	// ** PUBLIC PURE HELPERS ** //

	function toCTokens(uint amount, Exp memory cTokenExchangeRate) public pure returns (CTokenAmount memory) {
		uint cTokenAmount = _div(amount, cTokenExchangeRate);
		return CTokenAmount({val: cTokenAmount});
	}

	function toUnderlying(CTokenAmount memory amount, Exp memory cTokenExchangeRate) public pure returns (uint) {
		return _mul(amount.val, cTokenExchangeRate);
	}

	// *** PUBLIC VIEW GETTERS *** //

	// @dev Calculate protocol locked collateral and parBlocks, which is a measure of the fixed rate credit/debt.
	// * Uses int to keep negatives, for correct late blocks calc when a single swap is outstanding
	function getLockedCollateral(uint accruedBlocks, Exp memory cTokenExchangeRate) public view returns (CTokenAmount memory lockedCollateral, int parBlocksReceivingFixedNew, int parBlocksPayingFixedNew) {
		parBlocksReceivingFixedNew = _sub(parBlocksReceivingFixed, _mul(accruedBlocks, notionalReceivingFixed));
		parBlocksPayingFixedNew = _sub(parBlocksPayingFixed, _mul(accruedBlocks, notionalPayingFixed));

		// Par blocks can be negative during the first or last ever swap, so floor them to 0
		uint minFloatToReceive = _mul(_floor(parBlocksPayingFixedNew), minFloatRate);
		uint maxFloatToPay = _mul(_floor(parBlocksReceivingFixedNew), maxFloatRate);

		uint fixedToReceive = _mul(_floor(parBlocksReceivingFixedNew), avgFixedRateReceiving);
		uint fixedToPay = _mul(_floor(parBlocksPayingFixedNew), avgFixedRatePaying);

		uint minCredit = _add(fixedToReceive, minFloatToReceive);
		uint maxDebt = _add(fixedToPay, maxFloatToPay);

		if (maxDebt > minCredit) {
			lockedCollateral = toCTokens(_sub(maxDebt, minCredit), cTokenExchangeRate);
		} else {
			lockedCollateral = CTokenAmount({val:0});
		}
	}

	/* @dev Calculate protocol P/L by adding the cashflows since last accrual.
	 * 		supplierLiquidity += fixedReceived + floatReceived - fixedPaid - floatPaid
	 */
	function getSupplierLiquidity(uint accruedBlocks, Exp memory floatRate, Exp memory cTokenExchangeRate) public view returns (CTokenAmount memory supplierLiquidityNew) {
		uint floatPaid = _mul(notionalPayingFloat, floatRate);
		uint floatReceived = _mul(notionalReceivingFloat, floatRate);
		uint fixedPaid = _mul(accruedBlocks, _mul(notionalPayingFixed, avgFixedRatePaying));
		uint fixedReceived = _mul(accruedBlocks, _mul(notionalReceivingFixed, avgFixedRateReceiving));
		// TODO: safely handle supplierLiquidity going negative?
		supplierLiquidityNew = _sub(_add(supplierLiquidity, toCTokens(_add(fixedReceived, floatReceived), cTokenExchangeRate)), toCTokens(_add(fixedPaid, floatPaid), cTokenExchangeRate));
	}

	// @dev Get the rate for incoming swaps
	function getSwapRate(
		bool userPayingFixed,
		uint orderNotional,
		CTokenAmount memory lockedCollateral,
		CTokenAmount memory supplierLiquidity_,
		Exp memory cTokenExchangeRate
	) public view returns (Exp memory, int) {
		(uint rate, int rateFactorNew) = interestRateModel.getSwapRate(
			rateFactor,
			userPayingFixed,
			orderNotional,
			toUnderlying(lockedCollateral, cTokenExchangeRate),
			toUnderlying(supplierLiquidity_, cTokenExchangeRate)
		);
		return (_exp(rate), rateFactorNew);
	}

	// @dev The amount that must be locked up for the payFixed leg of a swap paying fixed. Used to calculate both the protocol and user's collateral.
	// = notionalAmount * SWAP_MIN_DURATION * (swapFixedRate - minFloatRate)
	function getPayFixedInitCollateral(Exp memory fixedRate, uint notionalAmount, Exp memory cTokenExchangeRate) public view returns (CTokenAmount memory) {
		Exp memory rateDelta = _sub(fixedRate, minFloatRate);
		uint amt = _mul(_mul(SWAP_MIN_DURATION, notionalAmount), rateDelta);
		return toCTokens(amt, cTokenExchangeRate);
	}

	// @dev The amount that must be locked up for the receiveFixed leg of a swap receiving fixed. Used to calculate both the protocol and user's collateral.
	// = notionalAmount * SWAP_MIN_DURATION * (maxFloatRate - swapFixedRate)
	function getReceiveFixedInitCollateral(Exp memory fixedRate, uint notionalAmount, Exp memory cTokenExchangeRate) public view returns (CTokenAmount memory) {
		Exp memory rateDelta = _sub(maxFloatRate, fixedRate);
		uint amt = _mul(_mul(SWAP_MIN_DURATION, notionalAmount), rateDelta);
		return toCTokens(amt, cTokenExchangeRate);
	}

	function getBenchmarkIndex() public view returns (Exp memory) {
		Exp memory borrowIndex = _exp(cToken.borrowIndex());
		require(borrowIndex.mantissa != 0, "Benchmark index is zero");
		uint blockDelta = _sub(getBlockNumber(), cToken.accrualBlockNumber());

		if (blockDelta == 0) {
			return borrowIndex;
		} else {
			Exp memory borrowRateMantissa = _exp(cToken.borrowRatePerBlock());
			Exp memory simpleInterestFactor = _mul(borrowRateMantissa, blockDelta);
			return _mul(borrowIndex, _add(simpleInterestFactor, ONE_EXP));
		}
	}

	function getExchangeRate() public view returns (Exp memory) {
		return _exp(cToken.exchangeRateStored());
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

	function _setCollateralRequirements(uint minFloatRateMantissa_, uint maxFloatRateMantissa_) external {
		require(msg.sender == admin, "Must be admin to set collateral requirements");
		require(minFloatRateMantissa_ < maxFloatRateMantissa_, "Min float rate must be below max float rate");
		require(minFloatRateMantissa_ < 1e11, "Min float rate above maximum");
		require(maxFloatRateMantissa_ > 1e10, "Max float rate below minimum");

		emit SetCollateralRequirements(minFloatRateMantissa_, maxFloatRateMantissa_);
		minFloatRate = _exp(minFloatRateMantissa_);
		maxFloatRate = _exp(maxFloatRateMantissa_);
	}

	function _pause(bool isPaused_) external {
		require(msg.sender == admin, "Must be admin to pause");
		require(isPaused_ != isPaused, "Must change isPaused");
		emit SetPause(isPaused_);
		isPaused = isPaused_;
	}

	function _transferComp(address dest, uint amount) external {
		require(msg.sender == admin, "Must be admin to transfer comp");
		emit CompTransferred(dest, amount);
		comp.transfer(dest, amount);
	}

	function _changeAdmin(address admin_) external {
		require(msg.sender == admin, "Must be admin to change admin");
		emit AdminChanged(admin, admin_);
		admin = admin_;
	}

}
