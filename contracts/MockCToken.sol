pragma solidity ^0.5.12;
	
import "./Rho.sol";

contract MockCToken is CTokenInterface {

	uint public borrowIndex;

	constructor(uint borrowIndex_) public {
		borrowIndex = borrowIndex_;
	}

	function setBorrowIndex(uint borrowIndex_) public {
		borrowIndex = borrowIndex;
	}
}