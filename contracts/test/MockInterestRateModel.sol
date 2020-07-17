pragma solidity ^0.6.10;

import "../InterestRateModel.sol";

contract MockInterestRateModel is InterestRateModel {
	uint public rate = 1e10;

	function setRate(uint rate_) public {
		rate = rate_;
	}

	function getRate(bool userPayingFixed, uint orderNotional) external view override returns (uint) {
		userPayingFixed;
		orderNotional;
		return rate;
	}
}
