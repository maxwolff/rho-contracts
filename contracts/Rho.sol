pragma solidity ^0.5.12;

import "./IERC20.sol";
import "./SafeMath.sol";
import "./InterestRateModel.sol";

contract BenchmarkInterface {
	uint public borrowIndex;
}

contract Rho {

	using SafeMath for *;

	InterestRateModelInterface public interestRateModel;
	IERC20 public underlying;
	BenchmarkInterface public benchmark;

	uint constant ONE_MANTISSA = 1e18;

	uint public benchmarkIndexStored;
	uint public lastAccrualBlock;

	uint public supplyIndex;
	uint public totalLiquidity;

	uint public fixedRateCreditPrincipal;
	uint public fixedRateDebtPrincipal;
	uint public floatRateDebtPrincipal;
	uint public floatRateCreditPrincipal;

	uint public avgFixedRateReceiving;
	uint public avgFixedRatePaying;

	uint public floatRateCreditBlocks;
	uint public floatRateDebtBlocks;

	uint public lockedCollateral;

	uint public fixedToReceive;
	uint public fixedToPay;

	uint public maxPayoutRate;
	uint public minPayoutRate;

	mapping(address => SupplyAccount) public accounts;

	struct SupplyAccount {
		uint amount;
		uint supplyBlock;
		uint supplyIndex;
	}

	constructor (InterestRateModelInterface interestRateModel_, BenchmarkInterface benchmark_, IERC20 underlying_) public {
		interestRateModel = interestRateModel_;
		benchmark = benchmark_;
		underlying = underlying_;
		supplyIndex = ONE_MANTISSA;

		benchmarkIndexStored = getBenchmarkIndex();
	}

	function supplyLiquidity(uint supplyAmount) public {
		accrueInterest();
		SupplyAccount storage account = accounts[msg.sender];

		uint truedUpLiquidity = 0;
		if (account.amount != 0 && account.supplyIndex != 0) {
			truedUpLiquidity = account.amount.mul(supplyIndex).div(account.supplyIndex);
		}

		account.amount = truedUpLiquidity.add(supplyAmount);
		account.supplyBlock = getBlockNumber();
		account.supplyIndex = supplyIndex;

		totalLiquidity = totalLiquidity.add(supplyAmount);

		underlying.transferFrom(msg.sender, address(this), supplyAmount);
	}


	// function removeLiquidity(uint withdrawAmount) public {

	// }

	// function openPayFixedSwap(uint notionalAmount) public {

	// }

	// function openReceiveFixedSwap(uint notionalAmount) public {

	// }

	// function closeSwap(uint orderNumber) public {

	// }

	function accrueInterest() internal {
		uint accruedBlocks = getBlockNumber() - lastAccrualBlock;
		if (accruedBlocks == 0) {
			return;
		}
		uint benchmarkIndex = getBenchmarkIndex();

		uint fixedReceived = fixedRateCreditPrincipal.mul(avgFixedRateReceiving).mul(accruedBlocks);
		uint fixedPaid = fixedRateDebtPrincipal.mul(avgFixedRatePaying).mul(accruedBlocks);

		uint floatRate = wdiv(benchmarkIndex, benchmarkIndexStored);

		uint floatPaid = floatRateDebtPrincipal.mul(floatRate.sub(ONE_MANTISSA));
		uint floatReceived = floatRateCreditPrincipal.mul(floatRate.sub(ONE_MANTISSA));

		floatRateDebtPrincipal = wmul(floatRateDebtPrincipal, floatRate);
		floatRateCreditPrincipal = wmul(floatRateCreditPrincipal, floatRate);

		// Update supplyIndex

		uint cashAccrued = fixedReceived.add(floatReceived).sub(fixedPaid).sub(floatPaid);

		if (cashAccrued > 0 && totalLiquidity > 0) {
			uint cashRateMantissa = cashAccrued.mul(ONE_MANTISSA).div(totalLiquidity);
			supplyIndex = supplyIndex.mul(cashRateMantissa.add(ONE_MANTISSA)).div(ONE_MANTISSA);
		}


		// Update lockedCollateral

		/* we avoid using the natural float debt and credit notional we have tracked, bc its compounded unpredictably
		 * we want to be able to make the net impact to `lockedCollateral` after`closeSwap()` 0.
		 * the hack is: fixed credit <> float debt since they are opposite sides of the same swap, but fixed isnt compounded
		 */

		floatRateCreditBlocks = floatRateCreditBlocks.sub(fixedRateDebtPrincipal.mul(accruedBlocks));
		uint minFloatToReceive = minPayoutRate.mul(floatRateCreditBlocks);

		floatRateDebtBlocks = floatRateDebtBlocks.sub(fixedRateCreditPrincipal.mul(accruedBlocks));
		uint maxFloatToPay = maxPayoutRate.mul(floatRateDebtBlocks);

		uint newFixedToPay = fixedToPay.sub(fixedPaid);
		uint newFixedToReceive = fixedToReceive.sub(fixedReceived);

		lockedCollateral = newFixedToPay.add(maxFloatToPay).sub(fixedToReceive).sub(minFloatToReceive);

		fixedToPay = newFixedToPay;
		fixedToReceive = newFixedToReceive;

		lastAccrualBlock = getBlockNumber();
		benchmarkIndexStored = benchmarkIndex;
	}

	function getBlockNumber() public returns (uint) {
		return block.number;
	}

	function getBenchmarkIndex() public returns (uint) {
		uint idx = benchmark.borrowIndex();
		require(idx != 0, "Unset benchmark index");
		return idx;
	}

	// ** ADMIN FUNCTIONS **

	// function _setInterestRateModel() {}

	// function _setCollateralRequirements(){}


	// ** MATH LIBS **

	function wmul(uint x, uint y) internal pure returns (uint) {
    	return x.mul(y).div(1e18);
    }

    function wdiv(uint x, uint y) internal pure returns (uint) {
    	return x.mul(1e18).div(y);
    }


}
