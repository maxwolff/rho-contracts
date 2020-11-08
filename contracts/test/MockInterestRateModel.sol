pragma solidity ^0.6.10;

import "../InterestRateModel.sol";

contract MockInterestRateModel is InterestRateModelInterface {
	uint public mockRate = 1e10;

	function setRate(uint rate_) public {
		mockRate = rate_;
	}

	function getSwapRate(int rateFactorPrev, bool userPayingFixed,  uint orderNotional, uint lockedCollateralUnderlying, uint supplierLiquidityUnderlying) external override view returns (uint rate, int rateFactorNew) {
		rateFactorPrev;
		userPayingFixed;
		orderNotional;
		lockedCollateralUnderlying;
		supplierLiquidityUnderlying;
		return (mockRate, 1);
	}
}
