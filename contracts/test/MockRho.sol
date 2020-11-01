// SPDX-License-Identifier: UNLICENSED
pragma experimental ABIEncoderV2;
pragma solidity ^0.6.10;

import "../Rho.sol";

contract MockRho is Rho {

	uint128 public blockNumber = 100;

	constructor (
		InterestRateModelInterface interestRateModel_,
		CTokenInterface cToken_,
		CompInterface comp_,
		uint128 minFloatRateMantissa_,
		uint128 maxFloatRateMantissa_,
		uint128 swapMinDuration_,
		uint128 supplyMinDuration_,
		address admin_
	)
		Rho(
			interestRateModel_,
			cToken_,
			comp_,
			minFloatRateMantissa_,
			maxFloatRateMantissa_,
			swapMinDuration_,
			supplyMinDuration_,
			admin_
		)
		public {}

	function setBlockNumber(uint128 blockNumber_) public returns (uint128) {
		blockNumber = blockNumber_;
	}

	function getBlockNumber() public view override returns (uint128) {
		return blockNumber;
	}

	function harnessAccrueInterest() public returns (CTokenAmount memory lockedCollateralNew){
		return accrue(getExchangeRate());
	}

	function advanceBlocks(uint128 blocks) public {
		blockNumber = blockNumber + blocks;
	}

	function advanceBlocksProtocol(uint128 blocks) public {
		advanceBlocks(blocks);

		(bool worked, bytes memory _) = address(cToken).call(abi.encodeWithSignature("advanceBlocks(uint128256)", blocks));
		require(worked == true, "Advance blocks didnt work");
		_;
	}
}
