// SPDX-License-Identifier: UNLICENSED
pragma experimental ABIEncoderV2;
pragma solidity ^0.6.10;

import "../Rho.sol";

contract MockRho is Rho {

	uint public blockNumber = 100;

	constructor (
		InterestRateModelInterface interestRateModel_,
		BenchmarkInterface benchmark_,
		CTokenInterface cTokenCollateral_,
		IERC20 rho_,
		uint minFloatRateMantissa_,
		uint maxFloatRateMantissa_,
		uint swapMinDuration_,
		uint supplyMinDuration_,
		address admin_
	)
		Rho(
			interestRateModel_,
			benchmark_,
			cTokenCollateral_,
			rho_,
			minFloatRateMantissa_,
			maxFloatRateMantissa_,
			swapMinDuration_,
			supplyMinDuration_,
			admin_
		)
		public {}

	function setBlockNumber(uint blockNumber_) public returns (uint) {
		blockNumber = blockNumber_;
	}

	function getBlockNumber() public view override returns (uint) {
		return blockNumber;
	}

	function harnessAccrueInterest() public returns (CTokenAmount memory lockedCollateralNew){
		return super.accrue();
	}

	function advanceBlocks(uint blocks) public {
		blockNumber = blockNumber + blocks;
	}
}
