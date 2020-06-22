pragma solidity ^0.5.12;

interface InterestRateModelInterface {
	function getRate(bool userPayingFixed, uint orderNotional) external view returns (uint);
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

	// 1e10 => 1e10 * 2102400 = 2.1024E16 => 2.1%
	function getRate(bool userPayingFixed, uint orderNotional) external view returns (uint) {
		return 1e10;
	}

	function getFee() public view returns (uint) {
		return 1;
	}

}
