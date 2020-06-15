pragma experimental ABIEncoderV2;
pragma solidity ^0.5.12;

import "../Rho.sol";

contract MockRho is Rho {

	uint blockNumber = 100;

	constructor (InterestRateModelInterface interestRateModel_, BenchmarkInterface benchmark_, IERC20 underlying_, uint minFloatRateMantissa_, uint maxFloatRateMantissa_)
		Rho(interestRateModel_, benchmark_, underlying_, minFloatRateMantissa_, maxFloatRateMantissa_)
		public {}

	function setBlockNumber(uint blockNumber_) public returns (uint) {
		blockNumber = blockNumber_;
	}

	function getBlockNumber() public view returns (uint) {
		return blockNumber;
	}

	function setSupplyIndex(uint supplyIndex_) public returns (uint) {
		supplyIndex = supplyIndex_;
	}

	function harnessAccrueInterest() public returns (uint lockedCollateralNew){
		return super.accrue();
	}

	function advanceBlocks(uint blocks) public {
		blockNumber = blockNumber + blocks;
	}
}
