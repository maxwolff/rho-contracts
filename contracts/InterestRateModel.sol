// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.6.10;

interface InterestRateModelInterface {
	function getSwapRate(
		int128 rateFactorPrev,
		bool userPayingFixed,
		uint128 orderNotional,
		uint128 lockedCollateralUnderlying,
		uint128 supplierLiquidityUnderlying
	) external view returns (uint128 rate, int128 rateFactorNew);
}

contract InterestRateModel is InterestRateModelInterface {

	uint128 public immutable yOffset;
	uint128 public immutable slopeFactor;
	uint128 public immutable rateFactorSensitivity;
	uint128 public immutable range;
	uint128 public immutable feeBase;
	uint128 public immutable feeSensitivity;

	constructor(
		uint128 yOffset_,
		uint128 slopeFactor_,
		uint128 rateFactorSensitivity_,
		uint128 feeBase_,
		uint128 feeSensitivity_,
		uint128 range_
	) public {
		require(slopeFactor_ > 0 && rateFactorSensitivity_ > 0 && range_ > 0 , "Zero params not allowed");

		yOffset = yOffset_;
		slopeFactor = slopeFactor_;
		rateFactorSensitivity = rateFactorSensitivity_;
		feeBase = feeBase_;
		feeSensitivity = feeSensitivity_;
		range = range_;
	}

	/* @dev Calculates the per-block interest rate to offer an incoming swap based on the rateFactor stored in Rho.sol.
	 * @param userPayingFixed : If the user is paying fixed in incoming swap
	 * @param orderNotional : Notional order size of the incoming swap
	 * @param lockedCollateralUnderlying : The amount of the protocol's liquidity that is locked at the time of the swap in underlying tokens
	 * @param supplierLiquidityUnderlying : Total amount of the protocol's liquidity in underlying tokens
	 */
	function getSwapRate(
		int128 rateFactorPrev,
		bool userPayingFixed,
		uint128 orderNotional,
		uint128 lockedCollateralUnderlying,
		uint128 supplierLiquidityUnderlying
	) external override view returns (uint128 rate, int128 rateFactorNew) {
		require(supplierLiquidityUnderlying != 0, "supplied liquidity 0");
		uint128 rfDelta = div(mul(rateFactorSensitivity, orderNotional), supplierLiquidityUnderlying);
		rateFactorNew = userPayingFixed ? add(rateFactorPrev, rfDelta) : sub1(rateFactorPrev, rfDelta);

		int128 num = mul(rateFactorNew, range);
		uint128 denom = sqrt(add(square(rateFactorNew), slopeFactor));

		uint128 baseRate = floor(add(div(num, denom), yOffset)); // can not be negative
		uint128 fee = getFee(lockedCollateralUnderlying, supplierLiquidityUnderlying);

		// base + yOffset +- fee
		if (userPayingFixed) {
			rate = add(baseRate, fee);
		} else {
			if (baseRate > fee) {
				rate = sub2(baseRate, fee);
			} else {
				rate = 0;
				// if the rate is negative, don't push rate factor even lower
				rateFactorNew = rateFactorPrev;
			}
		}
	}

	// @dev Calculates the fee to add to the rate. fee = feeBase + feeSensitivity * locked / total
	function getFee(uint128 lockedCollateralUnderlying, uint128 supplierLiquidityUnderlying) public view returns (uint128) {
		return add(feeBase, div(mul(feeSensitivity, lockedCollateralUnderlying), supplierLiquidityUnderlying));
	}

    // Source: https://github.com/Uniswap/uniswap-v2-core/blob/master/contracts/libraries/Math.sol
    // babylonian method (https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method)
    function sqrt(uint128 y) internal pure returns (uint128 z) {
        if (y > 3) {
            z = y;
            uint128 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

	// ** uint128 SAFE MATH ** //
	// Adapted from: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/math/SafeMath.sol

	function mul(uint128 a, uint128 b) internal pure returns (uint128) {
        if (a == 0) {
            return 0;
        }
        uint128 c = a * b;
        require(c / a == b, "SafeMath: Multiplication overflow");
        return c;
    }

    function div(uint128 a, uint128 b) internal pure returns (uint128) {
        require(b > 0, "SafeMath: Divide by zero");
        uint128 c = a / b;
        return c;
    }

    function add(uint128 a, uint128 b) internal pure returns (uint128) {
        uint128 c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }

    function sub2(uint128 a, uint128 b) pure internal returns (uint128) {
        require(b <= a, "subtraction underflow");
        return a - b;
    }

   	// ** int128 SAFE MATH ** //
   	// Adapted from: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/math/SignedSafeMath.sol
	int128 constant private _INT_MIN = -2**127;

    function div(int128 a, int128 b) internal pure returns (int128) {
        require(b != 0, "SignedSafeMath: division by zero");
        require(!(b == -1 && a == _INT_MIN), "SignedSafeMath: division overflow");

        int128 c = a / b;

        return c;
    }

    function mul(int128 a, int128 b) internal pure returns (int128) {
        if (a == 0) {
            return 0;
        }

        require(!(a == -1 && b == _INT_MIN), "SignedSafeMath: multiplication overflow");

        int128 c = a * b;
        require(c / a == b, "SignedSafeMath: multiplication overflow");

        return c;
    }

    function add(int128 a, int128 b) internal pure returns (int128) {
        int128 c = a + b;
        require((b >= 0 && c >= a) || (b < 0 && c < a), "SignedSafeMath: addition overflow");

        return c;
    }

    function sub(int128 a, int128 b) internal pure returns (int128) {
        int128 c = a - b;
        require((b >= 0 && c <= a) || (b < 0 && c > a), "SignedSafeMath: subtraction overflow");

        return c;
    }

   	// ** int128 => uint128 MATH ** //

   	// Set negative ints to 0
    function floor(int128 x) internal pure returns (uint128) {
		return x > 0 ? uint128(x) : 0;
	}

	function square(int128 a) internal pure returns (uint128) {
		return uint128(mul(a, a));
	}

	// ** uint128 => int128 MATH ** //

	int128 constant private _INT_MAX = 2**127 - 1;

    function add(int128 a, uint128 b) internal pure returns (int128){
        require(b < uint128(_INT_MAX), "SafeMath: int128 addition overflow detected");
        return add(a, int128(b));
    }

	function mul(int128 a, uint128 b) internal pure returns (int128) {
        require(b < uint128(_INT_MAX), "SafeMath: int128 multiplication overflow detected");
        return mul(a, int128(b));
	}

    function sub1(int128 a, uint128 b) internal pure returns (int128){
        require(b < uint128(_INT_MAX), "SafeMath: int128 subtraction overflow detected");
        return sub(a, int128(b));
    }

	function div(int128 a, uint128 b) internal pure returns (int128) {
        require(b < uint128(_INT_MAX), "SafeMath: int128 division overflow detected");
        return div(a, int128(b));
	}

}
