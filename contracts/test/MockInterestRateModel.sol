pragma solidity ^0.5.12;

import "../InterestRateModel.sol";

contract MockInterestRateModel is InterestRateModel {
	uint public rate = 1e10;

	function setRate(uint rate_) public {
		rate = rate_;
	}

	function getRate(bool userPayingFixed, uint orderNotional) external view returns (uint) {
		return rate;
	}
}
