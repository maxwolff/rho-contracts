// SPDX-License-Identifier: GPL-3.0
pragma experimental ABIEncoderV2;
pragma solidity ^0.6.10;

import "./InterestRateModel.sol";
import "./Math.sol";

interface CompInterface {
    function transfer(address to, uint128 value) external returns (bool);
}

interface CTokenInterface {
	function transferFrom(address from, address to, uint128 value) external returns (bool);
    function transfer(address to, uint128 value) external returns (bool);

	function borrowIndex() external view returns (uint128);
	function accrualBlockNumber() external view returns(uint128);
	function borrowRatePerBlock() external view returns(uint128);
	function exchangeRateStored() external view returns (uint128);
}

interface RhoInterface {
	function supply(uint128 cTokenSupplyAmount) external;
	function remove(uint128 removeCTokenAmount) external;
	function openPayFixedSwap(uint128 notionalAmount, uint128 maximumFixedRateMantissa) external returns (bytes32 swapHash);
	function openReceiveFixedSwap(uint128 notionalAmount, uint128 minFixedRateMantissa) external returns (bytes32 swapHash);
	function close(
		bool userPayingFixed,
		uint128 benchmarkIndexInit,
		uint128 initBlock,
		uint128 swapFixedRateMantissa,
		uint128 notionalAmount,
		uint128 userCollateralCTokens,
		address owner
	) external;
	event Supply(address indexed supplier, uint128 cTokenSupplyAmount, uint128 newSupplyAmount);
	event Remove(address indexed supplier, uint128 removeCTokenAmount, uint128 newSupplyValue);
	event OpenSwap(
		bytes32 indexed swapHash,
		bool userPayingFixed,
		uint128 benchmarkIndexInit,
		uint128 initBlock,
		uint128 swapFixedRateMantissa,
		uint128 notionalAmount,
		uint128 userCollateralCTokens,
		address indexed owner
	);
	event CloseSwap(
		bytes32 indexed swapHash,
		address indexed owner,
		uint128 userPayout,
		uint128 benchmarkIndexFinal
	);
	event Accrue(uint128 supplierLiquidityNew, uint128 lockedCollateralNew);
	event SetInterestRateModel(address newModel, address oldModel);
	event SetPause(bool isPaused);
	event AdminRenounced();
	event CompTransferred(address dest, uint128 amount);
	event SetCollateralRequirements(uint128 minFloatRateMantissa, uint128 maxFloatRateMantissa);
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

	uint128 public immutable SWAP_MIN_DURATION;
	uint128 public immutable SUPPLY_MIN_DURATION;

	uint128 public lastAccrualBlock;
	Exp public benchmarkIndexStored;

	/* Notional size of each leg, one adjusting for compounding and one static */
	uint128 public notionalReceivingFixed;
	uint128 public notionalPayingFloat;

	uint128 public notionalPayingFixed;
	uint128 public notionalReceivingFloat;

	/* Measure of outstanding swap obligations. 1 Unit = 1e18 notional * 1 block. Used to calculate collateral requirements */
	int128 public parBlocksReceivingFixed;
	int128 public parBlocksPayingFixed;

	/* Per block fixed / float interest rates used in collateral calculations */
	Exp public avgFixedRateReceiving;
	Exp public avgFixedRatePaying;

	/* Per block float rate bounds used in collateral calculations */
	Exp public maxFloatRate;
	Exp public minFloatRate;

	/* Protocol PnL */
	uint128 public supplyIndex;
	CTokenAmount public supplierLiquidity;

	int128 public rateFactor;// for interest rate model

	address public admin;
	bool public isPaused;

	mapping(address => SupplyAccount) public supplyAccounts;
	mapping(bytes32 => bool) public swaps;

	struct SupplyAccount {
		CTokenAmount amount;
		uint128 lastBlock;
		uint128 index;
	}

	struct Swap {
		bool userPayingFixed;
		uint128 notionalAmount;
		uint128 swapFixedRateMantissa;
		uint128 benchmarkIndexInit;
		uint128 userCollateralCTokens;
		uint128 initBlock;
		address owner;
	}

	constructor (
		InterestRateModelInterface interestRateModel_,
		CTokenInterface cToken_,
		CompInterface comp_,
		uint128 minFloatRateMantissa_,
		uint128 maxFloatRateMantissa_,
		uint128 swapMinDuration_,
		uint128 supplyMinDuration_,
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
		benchmarkIndexStored = _exp(5); //_exp(cToken_.borrowIndex());
		isPaused = false;
	}

	/* @dev Supplies liquidity to the protocol. Become the counterparty for all swap traders, in return for fees.
	 * @param cTokenSupplyAmount Amount to supply, in CTokens.
	 */
	function supply(uint128 cTokenSupplyAmount) public override {
		require(isPaused == false, "Market paused");
		CTokenAmount memory supplyAmount = CTokenAmount({val: cTokenSupplyAmount});

		Exp memory cTokenExchangeRate = getExchangeRate();
		accrue(cTokenExchangeRate);
		uint128 prevIndex = supplyAccounts[msg.sender].index;
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
	function remove(uint128 removeCTokenAmount) public override {
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

	function openPayFixedSwap(uint128 notionalAmount, uint128 maximumFixedRateMantissa) public override returns(bytes32 swapHash) {
		return openInternal(true, notionalAmount, maximumFixedRateMantissa);
	}

	function openReceiveFixedSwap(uint128 notionalAmount, uint128 minFixedRateMantissa) public override returns(bytes32 swapHash) {
		return openInternal(false, notionalAmount, minFixedRateMantissa);
	}

	/* @dev Opens a new interest rate swap
	 * @param userPayingFixed : The user can choose if they want to receive fixed or pay fixed (the protocol will take the opposite side)
	 * @param notionalAmount : The principal that interest rate payments will be based on
	 * @param fixedRateLimitMantissa : The maximum (if payingFixed) or minimum (if receivingFixed) rate the swap should succeed at. Prevents frontrunning attacks.
	 	* The amount of interest to pay over 2,102,400 blocks (~1 year), with 18 decimals of precision. Eg: 5% per block-year => 0.5e18.
	*/
	function openInternal(bool userPayingFixed, uint128 notionalAmount, uint128 fixedRateLimitMantissa) internal returns (bytes32 swapHash) {
		require(isPaused == false, "Market paused");
		require(notionalAmount >= 1e18, "Swap notional amount must exceed minimum");
		Exp memory cTokenExchangeRate = getExchangeRate();
		CTokenAmount memory lockedCollateral = accrue(cTokenExchangeRate);
		(Exp memory swapFixedRate, int128 rateFactorNew) = getSwapRate(userPayingFixed, notionalAmount, lockedCollateral, supplierLiquidity, cTokenExchangeRate);
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
	function openPayFixedSwapInternal(uint128 notionalAmount, Exp memory swapFixedRate, Exp memory cTokenExchangeRate) internal returns (CTokenAmount memory userCollateralCTokens) {
		uint128 notionalReceivingFixedNew = _add(notionalReceivingFixed, notionalAmount);
		uint128 notionalPayingFloatNew = _add(notionalPayingFloat, notionalAmount);

		int128 parBlocksReceivingFixedNew = _add(parBlocksReceivingFixed, _mul(SWAP_MIN_DURATION, notionalAmount));

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
	function openReceiveFixedSwapInternal(uint128 notionalAmount, Exp memory swapFixedRate, Exp memory cTokenExchangeRate) internal returns (CTokenAmount memory userCollateralCTokens) {
		uint128 notionalPayingFixedNew = _add(notionalPayingFixed, notionalAmount);
		uint128 notionalReceivingFloatNew = _add(notionalReceivingFloat, notionalAmount);

		int128 parBlocksPayingFixedNew = _add(parBlocksPayingFixed, _mul(SWAP_MIN_DURATION, notionalAmount));

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
		uint128 benchmarkIndexInit,
		uint128 initBlock,
		uint128 swapFixedRateMantissa,
		uint128 notionalAmount,
		uint128 userCollateralCTokens,
		address owner
	) public override {
		Exp memory cTokenExchangeRate = getExchangeRate();
		accrue(cTokenExchangeRate);
		bytes32 swapHash = keccak256(abi.encode(
			userPayingFixed,
			benchmarkIndexInit,
			initBlock,
			swapFixedRateMantissa,
			notionalAmount,
			userCollateralCTokens,
			owner
		));
		uint128 swapDuration = _sub(getBlockNumber(), initBlock);
		require(swapDuration >= SWAP_MIN_DURATION, "Premature close swap");
		require(swaps[swapHash] == true, "No active swap found");
		Exp memory benchmarkIndexRatio = _div(benchmarkIndexStored, _exp(benchmarkIndexInit));

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
		emit CloseSwap(swapHash, owner, userPayout.val, benchmarkIndexStored.mantissa);
		swaps[swapHash] = false;
		transferOut(owner, userPayout);
	}

	// @dev User paid fixed, protocol paid fixed
	function closePayFixedSwapInternal(
		uint128 swapDuration,
		Exp memory benchmarkIndexRatio,
		Exp memory swapFixedRate,
		uint128 notionalAmount,
		CTokenAmount memory userCollateral,
		Exp memory cTokenExchangeRate
	) internal returns (CTokenAmount memory userPayout) {
		uint128 notionalReceivingFixedNew = _sub(notionalReceivingFixed, notionalAmount);
		uint128 notionalPayingFloatNew = _sub(notionalPayingFloat, _mul(notionalAmount, benchmarkIndexRatio));

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
		int128 parBlocksReceivingFixedNew = _add(parBlocksReceivingFixed, _mul(notionalAmount, _sub(swapDuration, SWAP_MIN_DURATION)));

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
		uint128 swapDuration,
		Exp memory benchmarkIndexRatio,
		Exp memory swapFixedRate,
		uint128 notionalAmount,
		CTokenAmount memory userCollateral,
		Exp memory cTokenExchangeRate
	) internal returns (CTokenAmount memory userPayout) {
		uint128 notionalPayingFixedNew = _sub(notionalPayingFixed, notionalAmount);
		uint128 notionalReceivingFloatNew = _sub(notionalReceivingFloat, _mul(notionalAmount, benchmarkIndexRatio));

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
		int128 parBlocksPayingFixedNew = _add(parBlocksPayingFixed, _mul(notionalAmount, _sub(swapDuration, SWAP_MIN_DURATION)));

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
		require(getBlockNumber() >= lastAccrualBlock, "Block number decreasing");
		uint128 accruedBlocks = getBlockNumber() - lastAccrualBlock;
		(CTokenAmount memory lockedCollateralNew, int128 parBlocksReceivingFixedNew, int128 parBlocksPayingFixedNew) = getLockedCollateral(accruedBlocks, cTokenExchangeRate);

		if (accruedBlocks == 0) {
			return lockedCollateralNew;
		}

		Exp memory benchmarkIndexNew = getBenchmarkIndex();
		Exp memory benchmarkIndexRatio = _div(benchmarkIndexNew, benchmarkIndexStored);
		Exp memory floatRate = _sub(benchmarkIndexRatio, ONE_EXP);

		CTokenAmount memory supplierLiquidityNew = getSupplierLiquidity(accruedBlocks, floatRate, cTokenExchangeRate);

		// supplyIndex *= supplierLiquidityNew / supplierLiquidity
		uint128 supplyIndexNew = supplyIndex;
		if (supplierLiquidityNew.val != 0) {
			supplyIndexNew = _div(_mul(supplyIndex, supplierLiquidityNew), supplierLiquidity);
		}

		uint128 notionalPayingFloatNew = _mul(notionalPayingFloat, benchmarkIndexRatio);
		uint128 notionalReceivingFloatNew = _mul(notionalReceivingFloat, benchmarkIndexRatio);

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
		require(cToken.transferFrom(from, address(this), cTokenAmount.val) == true, "Transfer In Failed");
	}

	function transferOut(address to, CTokenAmount memory cTokenAmount) internal {
		require(cToken.transfer(to, cTokenAmount.val), "Transfer Out failed");
	}

	// ** PUBLIC PURE HELPERS ** //

	function toCTokens(uint128 amount, Exp memory cTokenExchangeRate) public pure returns (CTokenAmount memory) {
		uint128 cTokenAmount = _div(amount, cTokenExchangeRate);
		return CTokenAmount({val: cTokenAmount});
	}

	function toUnderlying(CTokenAmount memory amount, Exp memory cTokenExchangeRate) public pure returns (uint128) {
		return _mul(amount.val, cTokenExchangeRate);
	}

	// *** PUBLIC VIEW GETTERS *** //

	// @dev Calculate protocol locked collateral and parBlocks, which is a measure of the fixed rate credit/debt.
	// * Uses int128 to keep negatives, for correct late blocks calc when a single swap is outstanding
	function getLockedCollateral(uint128 accruedBlocks, Exp memory cTokenExchangeRate) public view returns (CTokenAmount memory lockedCollateral, int128 parBlocksReceivingFixedNew, int128 parBlocksPayingFixedNew) {
		parBlocksReceivingFixedNew = _sub(parBlocksReceivingFixed, _mul(accruedBlocks, notionalReceivingFixed));
		parBlocksPayingFixedNew = _sub(parBlocksPayingFixed, _mul(accruedBlocks, notionalPayingFixed));

		// Par blocks can be negative during the first or last ever swap, so floor them to 0
		uint128 minFloatToReceive = _mul(_floor(parBlocksPayingFixedNew), minFloatRate);
		uint128 maxFloatToPay = _mul(_floor(parBlocksReceivingFixedNew), maxFloatRate);

		uint128 fixedToReceive = _mul(_floor(parBlocksReceivingFixedNew), avgFixedRateReceiving);
		uint128 fixedToPay = _mul(_floor(parBlocksPayingFixedNew), avgFixedRatePaying);

		uint128 minCredit = _add(fixedToReceive, minFloatToReceive);
		uint128 maxDebt = _add(fixedToPay, maxFloatToPay);

		if (maxDebt > minCredit) {
			lockedCollateral = toCTokens(_sub(maxDebt, minCredit), cTokenExchangeRate);
		} else {
			lockedCollateral = CTokenAmount({val:0});
		}
	}

	/* @dev Calculate protocol P/L by adding the cashflows since last accrual.
	 * 		supplierLiquidity += fixedReceived + floatReceived - fixedPaid - floatPaid
	 */
	function getSupplierLiquidity(uint128 accruedBlocks, Exp memory floatRate, Exp memory cTokenExchangeRate) public view returns (CTokenAmount memory supplierLiquidityNew) {
		uint128 floatPaid = _mul(notionalPayingFloat, floatRate);
		uint128 floatReceived = _mul(notionalReceivingFloat, floatRate);
		uint128 fixedPaid = _mul(accruedBlocks, _mul(notionalPayingFixed, avgFixedRatePaying));
		uint128 fixedReceived = _mul(accruedBlocks, _mul(notionalReceivingFixed, avgFixedRateReceiving));

		CTokenAmount memory rec = toCTokens(_add(fixedReceived, floatReceived), cTokenExchangeRate);
		CTokenAmount memory paid = toCTokens(_add(fixedPaid, floatPaid), cTokenExchangeRate);
		supplierLiquidityNew = _subToZero(_add(supplierLiquidity, rec), paid);
	}

	// @dev Get the rate for incoming swaps
	function getSwapRate(
		bool userPayingFixed,
		uint128 orderNotional,
		CTokenAmount memory lockedCollateral,
		CTokenAmount memory supplierLiquidity_,
		Exp memory cTokenExchangeRate
	) public view returns (Exp memory, int128) {
		(uint128 ratePerBlockMantissa, int128 rateFactorNew) = interestRateModel.getSwapRate(
			rateFactor,
			userPayingFixed,
			orderNotional,
			toUnderlying(lockedCollateral, cTokenExchangeRate),
			toUnderlying(supplierLiquidity_, cTokenExchangeRate)
		);
		return (_exp(ratePerBlockMantissa), rateFactorNew);
	}

	// @dev The amount that must be locked up for the payFixed leg of a swap paying fixed. Used to calculate both the protocol and user's collateral.
	// = notionalAmount * SWAP_MIN_DURATION * (swapFixedRate - minFloatRate)
	function getPayFixedInitCollateral(Exp memory fixedRate, uint128 notionalAmount, Exp memory cTokenExchangeRate) public view returns (CTokenAmount memory) {
		Exp memory rateDelta = _sub(fixedRate, minFloatRate);
		uint128 amt = _mul(_mul(SWAP_MIN_DURATION, notionalAmount), rateDelta);
		return toCTokens(amt, cTokenExchangeRate);
	}

	// @dev The amount that must be locked up for the receiveFixed leg of a swap receiving fixed. Used to calculate both the protocol and user's collateral.
	// = notionalAmount * SWAP_MIN_DURATION * (maxFloatRate - swapFixedRate)
	function getReceiveFixedInitCollateral(Exp memory fixedRate, uint128 notionalAmount, Exp memory cTokenExchangeRate) public view returns (CTokenAmount memory) {
		Exp memory rateDelta = _sub(maxFloatRate, fixedRate);
		uint128 amt = _mul(_mul(SWAP_MIN_DURATION, notionalAmount), rateDelta);
		return toCTokens(amt, cTokenExchangeRate);
	}

	function getBenchmarkIndex() public view returns (Exp memory) {
		Exp memory borrowIndex = _exp(cToken.borrowIndex());
		require(borrowIndex.mantissa != 0, "Benchmark index is zero");
		uint128 accrualBlockNumber = cToken.accrualBlockNumber();
		require(getBlockNumber() >= accrualBlockNumber, "Bn decreasing");
		uint128 blockDelta = _sub(getBlockNumber(), accrualBlockNumber);

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

	function getBlockNumber() public view virtual returns (uint128) {
		return uint128(block.number);
	}

	/** ADMIN FUNCTIONS **/

	function _setInterestRateModel(InterestRateModel newModel) external {
		require(msg.sender == admin, "Must be admin to set interest rate model");
		require(newModel != interestRateModel, "Resetting to same model");
		emit SetInterestRateModel(address(newModel), address(interestRateModel));
		interestRateModel = newModel;
	}

	function _setCollateralRequirements(uint128 minFloatRateMantissa_, uint128 maxFloatRateMantissa_) external {
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

	function _transferComp(address dest, uint128 amount) external {
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
