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
	BenchmarkInterface public benchmark;

	uint public constant swapMinDuration = 345600;// 60 days in blocks, assuming 15s blocks

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

	constructor (InterestRateModelInterface interestRateModel_, BenchmarkInterface benchmark_, CTokenInterface cTokenCollateral_, uint minFloatRateMantissa_, uint maxFloatRateMantissa_) public {
		interestRateModel = interestRateModel_;
		benchmark = benchmark_;
		cTokenCollateral = cTokenCollateral_;
		minFloatRateMantissa = minFloatRateMantissa_;
		maxFloatRateMantissa = maxFloatRateMantissa_;

		supplyIndex = _oneExp().mantissa;

		benchmarkIndexStored = getBenchmarkIndex();
	}

	function supplyLiquidity(uint cTokenSupplyAmount) public {
		CTokenAmount memory supplyAmount = CTokenAmount({val: cTokenSupplyAmount});
		accrue();
		uint prevIndex = supplyAccounts[msg.sender].index;
		CTokenAmount memory prevSupplied = supplyAccounts[msg.sender].amount;
		bool initialized = prevSupplied.val != 0 && prevIndex != 0;

		prevSupplied = initialized ? _div(_mul(prevSupplied, supplyIndex), prevIndex) : CTokenAmount({val: 0});

		supplyAccounts[msg.sender].amount = _add(prevSupplied, supplyAmount);
		supplyAccounts[msg.sender].lastBlock = getBlockNumber();
		supplyAccounts[msg.sender].index = supplyIndex;

		supplierLiquidity = _add(supplierLiquidity, supplyAmount);

		transferIn(msg.sender, supplyAmount);
	}

	// function removeLiquidity(uint withdrawAmount) public {

	// }

	/* Opens a swap where the user pays the protocol-offered fixed rate and
	 * receives a Compound floating rate for swapMinDuration.
	*/

	function open(bool userPayingFixed, uint notionalAmount) public returns (bytes32 swapHash) {
		uint lockedCollateral = accrue();
		Exp memory swapFixedRate = getRate(userPayingFixed, notionalAmount);

		CTokenAmount memory userCollateralCTokens;
		if (userPayingFixed) {
			uint lockedCollateralHypothetical = _add(lockedCollateral, getReceiveFixedInitCollateral(swapFixedRate, notionalAmount));
			emit Test(lockedCollateralHypothetical, toUnderlying(supplierLiquidity), 0);
			require(lockedCollateralHypothetical <= toUnderlying(supplierLiquidity), "Insufficient protocol collateral");
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

		userCollateralCTokens = toCTokens(getPayFixedInitCollateral(swapFixedRate, notionalAmount));

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
		CTokenAmount memory userCollateralCTokens
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
		// emit Test(userCollateralCTokens.val, toUnderlying(floatLeg), floatLeg.val);
		userPayout = _sub(_add(userCollateralCTokens, floatLeg), fixedLeg);

		notionalReceivingFixed = notionalReceivingFixedNew;
		notionalPayingFloat = notionalPayingFloatNew;
		parBlocksReceivingFixed = parBlocksReceivingFixedNew;
		avgFixedRateReceivingMantissa = avgFixedRateReceivingNew.mantissa;

		return userPayout;
	}

	function accrue() internal returns (uint lockedCollateralNew) {
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

		emit Accrue(supplierLiquidityNew, lockedCollateralNew);
		return lockedCollateralNew;
	}

	function getLockedCollateralInternal(uint accruedBlocks) internal view returns (uint lockedCollateral, int parBlocksReceivingFixedNew, int parBlocksPayingFixedNew) {
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
			lockedCollateral = _sub(maxDebt, minCredit);
		} else {
			lockedCollateral = 0;
		}
	}

	/*  The amount that must be locked up for the leg of a swap paying fixed
	 *  = notionalAmount * swapMinDuration * (swapFixedRate - minFloatRate)
	 */
	function getPayFixedInitCollateral(Exp memory fixedRate, uint notionalAmount) public returns (uint) {
		Exp memory rateDelta = _sub(fixedRate, _exp(minFloatRateMantissa));
		emit Test(swapMinDuration, notionalAmount, rateDelta.mantissa);
		return _mul(_mul(swapMinDuration, notionalAmount), rateDelta);
	}

	/* The amount that must be locked up for the leg of a swap receiving fixed
	 * = notionalAmount * swapMinDuration * (maxFloatRate - swapFixedRate)
	 */
	function getReceiveFixedInitCollateral(Exp memory fixedRate, uint notionalAmount) public view returns (uint) {
		Exp memory rateDelta = _sub(_exp(maxFloatRateMantissa), fixedRate);
		return _mul(_mul(swapMinDuration, notionalAmount), rateDelta);
	}

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


	function getLockedCollateral() external view returns (uint lockedCollateral) {
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
