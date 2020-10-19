// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.10;

import "../Rho.sol";
import "./FaucetToken.sol";

interface MockCTokenInterface {
	function borrowIndex() external view returns (uint);
	function accrualBlockNumber() external view returns(uint);
	function borrowRatePerBlock() external view returns(uint);
	function exchangeRateStored() external view returns (uint);
}

contract MockCToken is FaucetToken, MockCTokenInterface {

	uint public override borrowIndex = 1e18;
	uint public override accrualBlockNumber = 100;
	uint public override borrowRatePerBlock;

	uint public exchangeRate;

	constructor(
		uint _initialExchangeRate,
		uint _borrowRatePerBlockMantissa,
		uint256 _initialAmount,
		string memory _tokenName,
		uint8 _decimalUnits,
		string memory _tokenSymbol
	)
		public FaucetToken(_initialAmount, _tokenName, _decimalUnits, _tokenSymbol)
	{
		borrowRatePerBlock = _borrowRatePerBlockMantissa;
		exchangeRate = _initialExchangeRate * 1e18;
	}

	function setBorrowIndex(uint borrowIndex_) public {
		borrowIndex = borrowIndex_;
	}

	function setAccrualBlockNumber(uint bn) public {
		accrualBlockNumber = bn;
	}

	function advanceBlocks(uint blocks) public {
		accrualBlockNumber += blocks;
	}

	function exchangeRateStored() public override view returns (uint) {
		return exchangeRate;
	}
}
