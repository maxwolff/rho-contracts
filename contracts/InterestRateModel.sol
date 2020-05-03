pragma solidity ^0.5.12;

interface InterestRateModelInterface {
	function getRate(uint swapType, uint orderNotional) external returns (uint);
	function getFee() external view returns (uint);
}

contract InterestRateModel is InterestRateModelInterface {

	// constructor(
	// 		uint _yOffset,
	// 		uint slopeFactor_,
	// 		uint rateFactorSensitivity_,
	// 		uint feeBase_,
	// 		uint feeSensitivity_
	// ) {

	// }

	function getRate(uint swapType, uint orderNotional) public returns (uint) {
		return 1;
	}

	function getFee() public view returns (uint) {
		return 1;
	}

}
