// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.6.10;

interface InterestRateModelInterface {
	function getSwapRate(
		int rateFactorPrev,
		bool userPayingFixed,
		uint orderNotional,
		uint lockedCollateralUnderlying,
		uint supplierLiquidityUnderlying
	) external view returns (uint rate, int rateFactorNew);
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
		require(slopeFactor_ > 0, "Zero slopeFactor not allowed");
		slopeFactor = slopeFactor_;
		rateFactorSensitivity = rateFactorSensitivity_;
		feeBase = feeBase_;
		feeSensitivity = feeSensitivity_;
		range = range_;
	}

	/* @dev Calculates the per-block interest rate to offer an incoming swap based on the rateFactor stored in Rho.sol.
	 * @param userPayingFixed : If the user is paying fixed in incoming swap
	 * @param orderNotional : Notional order size of the incoming swap
	 * @param lockedCollateralUnderlying : The amount of the protocol's liquidity that is locked at the time of the swap
	 * @param supplierLiquidityUnderlying : Total amount of the protocol's liquidity
	 */
	function getSwapRate(
		int rateFactorPrev,
		bool userPayingFixed,
		uint orderNotional,
		uint lockedCollateralUnderlying,
		uint supplierLiquidityUnderlying
	) external override view returns (uint rate, int rateFactorNew) {
		int delta = int(div(mul(rateFactorSensitivity, orderNotional), supplierLiquidityUnderlying));
		rateFactorNew = userPayingFixed ? rateFactorPrev + delta : rateFactorPrev - delta;

		// num = range * rateFactor
		int num = mul(int(range), rateFactorNew);

		// denom = sqrt(rateFactor ^2 + slopeFactor)
		int inner = add(mul(rateFactorNew, rateFactorNew), int(slopeFactor));
		int denom = sqrt(inner);

		int raw = div(num, denom);
		uint baseRate = uint(add(raw, int(yOffset)));
		rate = add(baseRate, getFee(lockedCollateralUnderlying, supplierLiquidityUnderlying));
		require(rate > 0, "Rate is below 0");
	}

	// @dev Calculates the fee to add to the rate. fee = baseFee + feeSensitivity * locked / total
	function getFee(uint lockedCollateralUnderlying, uint supplierLiquidityUnderlying) public view returns (uint) {
		return add(feeBase, div(mul(feeSensitivity, lockedCollateralUnderlying), supplierLiquidityUnderlying));
	}

	// @dev Adapted from: https://github.com/ethereum/dapp-bin/pull/50/files */
    function sqrt(int x) internal pure returns (int y) {
    	// just using int to avoid recasting, x should never be 0
        require(x >= 0, "Can't square root a negative number");
        if (x == 0) return 0;
        else if (x <= 3) return 1;
        int z = (x + 1) / 2;
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


	// ** UINT SAFE MATH ** //
	// Adapted from https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/math/SafeMath.sol

	function mul(uint256 a, uint256 b) internal pure returns (uint256) {
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

   	// ** INT SAFE MATH ** //
   	// Adapted from https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/math/SignedSafeMath.sol
	int256 constant private _INT256_MIN = -2**255;


    function div(int256 a, int256 b) internal pure returns (int256) {
        require(b != 0, "SignedSafeMath: division by zero");
        require(!(b == -1 && a == _INT256_MIN), "SignedSafeMath: division overflow");

        int256 c = a / b;

        return c;
    }

    function mul(int256 a, int256 b) internal pure returns (int256) {
        if (a == 0) {
            return 0;
        }

        require(!(a == -1 && b == _INT256_MIN), "SignedSafeMath: multiplication overflow");

        int256 c = a * b;
        require(c / a == b, "SignedSafeMath: multiplication overflow");

        return c;
    }

    function add(int256 a, int256 b) internal pure returns (int256) {
        int256 c = a + b;
        require((b >= 0 && c >= a) || (b < 0 && c < a), "SignedSafeMath: addition overflow");

        return c;
    }

    function sub(int256 a, int256 b) internal pure returns (int256) {
        int256 c = a - b;
        require((b >= 0 && c <= a) || (b < 0 && c > a), "SignedSafeMath: subtraction overflow");

        return c;
    }

}
