pragma experimental ABIEncoderV2;
pragma solidity ^0.5.12;

import "./IERC20.sol";
import "./SafeMath.sol";
import "./InterestRateModel.sol";
import "./Math.sol";

interface BenchmarkInterface {
	function getBorrowIndex() external view returns (uint);
}

contract Rho is Math {

	InterestRateModelInterface public interestRateModel;
	IERC20 public underlying;
	BenchmarkInterface public benchmark;

	uint public constant swapMinDuration = 345600;// 60 days in blocks, assuming 15s blocks

	uint public lastAccrualBlock;
	uint public benchmarkIndexStored;

	/* notional size of each leg */
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
	uint public totalLiquidity;

	mapping(address => SupplyAccount) public accounts;
	mapping(bytes32 => bool) public payFixedSwaps;

	event Test(uint a, uint b, uint c);
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

		supplyIndex = _oneExp().mantissa;

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


	function openPayFixedSwap(uint notionalAmount) public returns (bytes32 swapHash) {
		uint lockedCollateral = accrue();
		Exp memory swapFixedRate = _exp(interestRateModel.getRatePayFixed(notionalAmount));

		// protocol is receiving fixed, if user is paying fixed
		uint lockedCollateralHypothetical = _add(lockedCollateral, getReceiveFixedInitCollateral(swapFixedRate, notionalAmount));

		require(lockedCollateralHypothetical <= totalLiquidity, "Insufficient protocol collateral");

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

		uint userCollateral = getPayFixedInitCollateral(swapFixedRate, notionalAmount);

		swapHash = keccak256(abi.encode(
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

		avgFixedRateReceivingMantissa = avgFixedRateReceivingNew.mantissa;
		notionalReceivingFixed = notionalReceivingFixedNew;
		parBlocksReceivingFixed = parBlocksReceivingFixedNew;

		notionalPayingFloat = notionalPayingFloatNew;

		// require true?
		underlying.transferFrom(msg.sender, address(this), userCollateral);
		return swapHash;
	}

	// function openReceiveFixedSwap(uint notionalAmount) public {
	// }

	struct ClosePayFixedLocalVars {
		Exp actualFloatRate;
		uint swapFixedRateMantissa;
	}

	function closePayFixedSwap(
		uint benchmarkInitIndex,
		uint initBlock,
		uint swapFixedRateMantissa,
		uint notionalAmount,
		uint priorMaxFloatRateMantissa,
		uint userCollateral,
		address owner
	) public {
		accrue();

		ClosePayFixedLocalVars memory vars;
		vars.swapFixedRateMantissa = swapFixedRateMantissa;
		bytes32 swapHash = keccak256(abi.encode(
			benchmarkInitIndex,
			initBlock,
			swapFixedRateMantissa,
			notionalAmount,
			priorMaxFloatRateMantissa,
			userCollateral,
			owner
		));
		uint swapDuration = _sub(getBlockNumber(), initBlock);
		require(swapDuration >= swapMinDuration, "Premature close swap");

		require(payFixedSwaps[swapHash] == true, "No active swap found");

		vars.actualFloatRate = _div(_exp(benchmarkIndexStored), _exp(benchmarkInitIndex));

		uint notionalReceivingFixedNew = _sub(notionalReceivingFixed, notionalAmount);
		uint notionalPayingFloatNew = _sub(notionalPayingFloat, _mul(notionalAmount, vars.actualFloatRate));

		/* avgFixedRateReceiving = avgFixedRateReceiving * notionalReceivingFixed - swapFixedRateMantissa * notionalAmount / notionalReceivingFixedNew */
		Exp memory avgFixedRateReceivingNew;
		if (notionalReceivingFixedNew != 0 ){
			Exp memory numerator = _sub(_mul(_exp(avgFixedRateReceivingMantissa), notionalReceivingFixed), _mul(_exp(vars.swapFixedRateMantissa), notionalAmount));
			avgFixedRateReceivingNew = _div(numerator, notionalReceivingFixedNew);
		} else {
			avgFixedRateReceivingNew = _exp(0);
		}

		/* Late blocks adjustments. The protocol reserved enough collateral for this swap for ${swapDuration}, but its has been ${swapDuration + lateBlocks}.
		 * We have consistently decreased the lockedCollateral from the `open` fn in every `accrue`, and in fact we have decreased it by more than we ever added in the first place.
		 */


		int parBlocksReceivingFixedNew;
		{
			uint lateBlocks = _sub(swapDuration, swapMinDuration);
			parBlocksReceivingFixedNew = _add(parBlocksReceivingFixed, _mul(notionalAmount, lateBlocks));
		}

		/* Calculate the user's payout:
		 * 		fixedLeg = notionalAmount * swapDuration * swapFixedRate
		 * 		floatLeg = notionalAmount * min(actualFloatRate, priorMaxFloatRate)
		 * 		userPayout = userCollateral + fixedLeg - floatLeg
		 */

		 /// ***** TODO: max the user payout. Potentially using max float rate.
		uint userPayout;
		{
			uint fixedLeg = _mul(_mul(notionalAmount, swapDuration), _exp(vars.swapFixedRateMantissa));
			uint floatLeg = _mul(notionalAmount,_sub(vars.actualFloatRate, _oneExp()));
			userPayout = _sub(_add(userCollateral, floatLeg), fixedLeg);
		}

		/* Apply effects and interactions */

		payFixedSwaps[swapHash] = false;

		notionalReceivingFixed = notionalReceivingFixedNew;
		notionalPayingFloat = notionalPayingFloatNew;

		parBlocksReceivingFixed = parBlocksReceivingFixedNew;
		avgFixedRateReceivingMantissa = avgFixedRateReceivingNew.mantissa;

		underlying.transfer(owner, userPayout);
	}

	function accrue() internal returns (uint lockedCollateralNew) {
		uint accruedBlocks = getBlockNumber() - lastAccrualBlock;

		/* Calculate protocol fixed rate credit/debt. Use int to keep negatives, for correct late blocks calc even after underflow */
		int parBlocksReceivingFixedNew = _sub(parBlocksReceivingFixed, _mul(accruedBlocks, notionalReceivingFixed));
		int parBlocksPayingFixedNew = _sub(parBlocksPayingFixed, _mul(accruedBlocks, notionalPayingFixed));

		lockedCollateralNew = getLockedCollateral(parBlocksPayingFixedNew, parBlocksReceivingFixedNew);

		if (accruedBlocks == 0) {
			return lockedCollateralNew;
		}

		Exp memory benchmarkIndexNew = _exp(getBenchmarkIndex());
		Exp memory benchmarkIndexRatio = _div(benchmarkIndexNew, _exp(benchmarkIndexStored));
		require(benchmarkIndexRatio.mantissa >= _oneExp().mantissa, "Decreasing float rate");
		// TODO: put avgRateMantissa vars into EXPs

		/*  Calculate protocol P/L by adding the cashflows since last accrual
		 * 		totalLiquidity += fixedReceived + floatReceived - fixedPaid - floatPaid
		 * 		supplyIndex *= totalLiquidityNew / totalLiquidity
		 */
		uint totalLiquidityNew;
		{
			uint floatPaid = _mul(notionalPayingFloat, _sub(benchmarkIndexRatio, _oneExp()));
			uint floatReceived = _mul(notionalReceivingFloat, _sub(benchmarkIndexRatio, _oneExp()));
			uint fixedPaid = _mul(accruedBlocks, _mul(notionalPayingFixed, _exp(avgFixedRatePayingMantissa)));
			uint fixedReceived = _mul(accruedBlocks, _mul(notionalReceivingFixed, _exp(avgFixedRateReceivingMantissa)));
			// XXX: safely handle totalLiquidity going negative?
			totalLiquidityNew = _sub(_add(totalLiquidity, _add(fixedReceived, floatReceived)), _add(fixedPaid, floatPaid));
		}

		uint supplyIndexNew = supplyIndex;
		if (totalLiquidityNew != 0) {
			supplyIndexNew = _div(_mul(supplyIndex, totalLiquidityNew), totalLiquidity);
		}

		/*  Compound float notional */
		uint notionalPayingFloatNew = _mul(notionalPayingFloat, benchmarkIndexRatio);
		uint notionalReceivingFloatNew = _mul(notionalReceivingFloat, benchmarkIndexRatio);

		// ** APPLY EFFECTS **

		parBlocksPayingFixed = parBlocksPayingFixedNew;
		parBlocksReceivingFixed = parBlocksReceivingFixedNew;

		totalLiquidity = totalLiquidityNew;
		supplyIndex = supplyIndexNew;

		notionalPayingFloat = notionalPayingFloatNew;
		notionalReceivingFloat = notionalReceivingFloatNew;

		benchmarkIndexStored = benchmarkIndexNew.mantissa;
		lastAccrualBlock = getBlockNumber();

		emit Accrue(totalLiquidityNew, lockedCollateralNew);
		return lockedCollateralNew;
	}

	function getLockedCollateral(int parBlocksPayingFixedNew, int parBlocksReceivingFixedNew) public view returns (uint) {
		uint minFloatToReceive = _mul(_toUint(parBlocksPayingFixedNew), _exp(minFloatRateMantissa));
		uint maxFloatToPay = _mul(_toUint(parBlocksReceivingFixedNew), _exp(maxFloatRateMantissa));

		uint fixedToReceive = _mul(_toUint(parBlocksReceivingFixedNew), _exp(avgFixedRateReceivingMantissa));
		uint fixedToPay = _mul(_toUint(parBlocksPayingFixedNew), _exp(avgFixedRatePayingMantissa));

		uint minCredit = _add(fixedToReceive, minFloatToReceive);
		uint maxDebt = _add(fixedToPay, maxFloatToPay);

		if (maxDebt > minCredit) {
			return _sub(maxDebt, minCredit);
		} else {
			return 0;
		}
	}

	/*  The amount that must be locked up for the leg of a swap paying fixed
	 *  = notionalAmount * swapMinDuration * (swapFixedRate - minFloatRate)
	 */
	function getPayFixedInitCollateral(Exp memory fixedRate, uint notionalAmount) public view returns (uint) {
		Exp memory rateDelta = _sub(fixedRate, _exp(minFloatRateMantissa));
		return _mul(_mul(swapMinDuration, notionalAmount), rateDelta);
	}

	/* The amount that must be locked up for the leg of a swap receiving fixed
	 * = notionalAmount * swapMinDuration * (maxFloatRate - swapFixedRate)
	 */
	function getReceiveFixedInitCollateral(Exp memory fixedRate, uint notionalAmount) public view returns (uint) {
		Exp memory rateDelta = _sub(_exp(maxFloatRateMantissa), fixedRate);
		return _mul(_mul(swapMinDuration, notionalAmount), rateDelta);
	}

	function getBlockNumber() public view returns (uint) {
		return block.number;
	}

	function getBenchmarkIndex() public view returns (uint) {
		uint idx = benchmark.getBorrowIndex();
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
