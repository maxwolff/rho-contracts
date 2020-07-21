pragma solidity ^0.6.10;

interface InterestRateModelInterface {
	function getSwapRate(bool userPayingFixed, int rateFactorPrev, uint orderNotional, uint lockedCollateralUnderlying, uint supplierLiquidityUnderlying) external view returns (uint rate, int rateFactorNew);
}

contract InterestRateModel is InterestRateModelInterface {

	uint public immutable yOffset;
	uint public immutable slopeFactor;
	uint public immutable rateFactorSensitivity;
	uint public immutable range;
	uint public immutable feeBase;
	uint public immutable feeSensitivity;

	constructor(
		uint yOffset_,
		uint slopeFactor_,
		uint rateFactorSensitivity_,
		uint feeBase_,
		uint feeSensitivity_,
		uint range_
	) public {
		yOffset = yOffset_;
		slopeFactor = slopeFactor_;
		rateFactorSensitivity = rateFactorSensitivity_;
		feeBase = feeBase_;
		feeSensitivity = feeSensitivity_;
		range = range_;
	}

	// TODO: clean up
	function getSwapRate(bool userPayingFixed, int rateFactorPrev, uint orderNotional, uint lockedCollateralUnderlying, uint supplierLiquidityUnderlying) external override view returns (uint rate, int rateFactorNew) {
		int delta = int(div(mul(rateFactorSensitivity, orderNotional), supplierLiquidityUnderlying));
		rateFactorNew = userPayingFixed ? rateFactorPrev + delta : rateFactorPrev - delta;

		int num = int(range) * rateFactorNew;
		uint denom = sqrt(uint(rateFactorNew * rateFactorNew) + slopeFactor);
		int raw = num / int(denom);
		uint baseRate = uint(raw + int(yOffset));
		rate = baseRate + getFee(lockedCollateralUnderlying, supplierLiquidityUnderlying);
	}

	// fee = baseFee + feeSensitivity * locked / total
	function getFee(uint lockedCollateralUnderlying, uint supplierLiquidityUnderlying) public view returns (uint) {
		return add(feeBase, div(mul(feeSensitivity, lockedCollateralUnderlying), supplierLiquidityUnderlying));
	}

	/* https://github.com/ethereum/dapp-bin/pull/50/files */
    /// ensures { to_int result * to_int result <= to_int arg_x < (to_int result + 1) * (to_int result + 1) }
    function sqrt(uint x) internal pure returns (uint y) {
        if (x == 0) return 0;
        else if (x <= 3) return 1;
        uint z = (x + 1) / 2;
        y = x;
        while (z < y)
        /// invariant { to_int !_z = div ((div (to_int arg_x) (to_int !_y)) + (to_int !_y)) 2 }
        /// invariant { to_int arg_x < (to_int !_y + 1) * (to_int !_y + 1) }
        /// invariant { to_int arg_x < (to_int !_z + 1) * (to_int !_z + 1) }
        /// variant { to_int !_y }
        {
            y = z;
            z = (x / z + z) / 2;
        }
    }


	// ** SAFE MATH ** //

	function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
        // benefit is lost if 'b' is also tested.
        // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
        if (a == 0) {
            return 0;
        }
        uint256 c = a * b;
        require(c / a == b, "Multiplication overflow");
        return c;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "Divide by zero");
        uint256 c = a / b;
        return c;
    }

    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }

}
