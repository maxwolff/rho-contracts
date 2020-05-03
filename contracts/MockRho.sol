pragma solidity ^0.5.12;

import "./Rho.sol";
import "./InterestRateModel.sol";

contract MockRho is Rho {

	uint blockNumber;

	constructor (InterestRateModelInterface interestRateModel_, BenchmarkInterface benchmark_, IERC20 underlying_)
		Rho(interestRateModel_, benchmark_, underlying_)
		public {}

	function setBlockNumber(uint blockNumber_) public returns (uint) {
		blockNumber = blockNumber_;
	}

	function getBlockNumber() public returns (uint) {
		return blockNumber;
	}

	function setSupplyIndex(uint supplyIndex_) public returns (uint) {
		supplyIndex = supplyIndex_;
	}

	function harnessAccrueInterest() public {
		super.accrueInterest();
	}

}
