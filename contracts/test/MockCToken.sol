// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.6.10;

import "../Rho.sol";
import "./FaucetToken.sol";

contract MockCToken is BenchmarkInterface, FaucetToken {

	uint public borrowIndex = 1e18;
	uint public exchangeRate;

	constructor(uint initialExchangeRate, uint256 _initialAmount, string memory _tokenName, uint8 _decimalUnits, string memory _tokenSymbol)
		public FaucetToken(_initialAmount, _tokenName, _decimalUnits, _tokenSymbol)
	{
		exchangeRate = initialExchangeRate * 1e18;
	}

	function setBorrowIndex(uint borrowIndex_) public {
		borrowIndex = borrowIndex_;
	}

	function getBorrowIndex() public view override returns (uint) {
		return borrowIndex;
	}

	function exchangeRateStored() public view returns (uint) {
		return exchangeRate;
	}
}

contract BadBenchmark is BenchmarkInterface {
	function getBorrowIndex() public view override returns (uint) {
		return 0;
	}
}
