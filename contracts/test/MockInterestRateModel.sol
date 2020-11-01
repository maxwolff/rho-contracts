// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.10;

import "../InterestRateModel.sol";

contract MockInterestRateModel is InterestRateModelInterface {
	uint128 public mockRate = 1e10;

	function setRate(uint128 rate_) public {
		mockRate = rate_;
	}

	function getSwapRate(int128 rateFactorPrev, bool userPayingFixed,  uint128 orderNotional, uint128 lockedCollateralUnderlying, uint128 supplierLiquidityUnderlying) external override view returns (uint128 rate, int128 rateFactorNew) {
		rateFactorPrev;
		userPayingFixed;
		orderNotional;
		lockedCollateralUnderlying;
		supplierLiquidityUnderlying;
		return (mockRate, 1);
	}
}
