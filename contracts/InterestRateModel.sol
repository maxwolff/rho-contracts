pragma solidity ^0.6.10;

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

	function getRate(bool userPayingFixed, uint orderNotional) external view virtual override returns (uint) {
		userPayingFixed;
		orderNotional;
		// 1e10 * 2102400 /1e18 = 2.1%
		return 1e10;
	}

	function getFee() public view override returns (uint) {
		return 1;
	}

}
