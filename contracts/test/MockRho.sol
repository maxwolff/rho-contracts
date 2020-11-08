pragma experimental ABIEncoderV2;
pragma solidity ^0.6.10;

import "../Rho.sol";

contract MockRho is Rho {

	uint public blockNumber = 100;

	constructor (
		InterestRateModelInterface interestRateModel_,
		CTokenInterface cToken_,
		CompInterface comp_,
		uint minFloatRateMantissa_,
		uint maxFloatRateMantissa_,
		uint swapMinDuration_,
		uint supplyMinDuration_,
		address admin_,
		uint liquidityLimitCTokens_
	)
		Rho(
			interestRateModel_,
			cToken_,
			comp_,
			minFloatRateMantissa_,
			maxFloatRateMantissa_,
			swapMinDuration_,
			supplyMinDuration_,
			admin_,
			liquidityLimitCTokens_
		)
		public {}

	function setBlockNumber(uint blockNumber_) public returns (uint) {
		blockNumber = blockNumber_;
	}

	function getBlockNumber() public view override returns (uint) {
		return blockNumber;
	}

	function harnessAccrueInterest() public returns (CTokenAmount memory lockedCollateralNew){
		return accrue(getExchangeRate());
	}

	function advanceBlocks(uint blocks) public {
		blockNumber = blockNumber + blocks;
	}

	function advanceBlocksProtocol(uint blocks) public {
		advanceBlocks(blocks);

		(bool worked, bytes memory _) = address(cToken).call(abi.encodeWithSignature("advanceBlocks(uint256)", blocks));
		require(worked == true, "Advance blocks didnt work");
		_;
	}
}
