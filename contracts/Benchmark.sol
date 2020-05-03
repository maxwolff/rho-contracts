pragma solidity ^0.5.12;

import "./Rho.sol";

contract MockCToken is BenchmarkInterface {

	uint public borrowIndex = 1e18;

	function setBorrowIndex(uint borrowIndex_) public {
		borrowIndex = borrowIndex_;
	}
}

contract BadBenchmark is BenchmarkInterface {
	uint public borrowIndex = 0;
}
