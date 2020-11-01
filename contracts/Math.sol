// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.6.10;

contract Types {

    /*@dev A type to store amounts of cTokens, to make sure they are not confused with amounts of the underlying */
    struct CTokenAmount {
        uint128 val;
    }

    /* @dev A type to store numbers scaled up by 18 decimals*/
    struct Exp {
        uint128 mantissa;
    }
}

/* Always returns type of left side param */
contract Math is Types {

	uint128 constant EXP_SCALE = 1e18;
    Exp ONE_EXP = Exp({mantissa: EXP_SCALE});

    function _exp(uint128 num) pure internal returns (Exp memory) {
    	return Exp({mantissa: num});
    }

    function _floor(int128 a) pure internal returns (uint128) {
        return a > 0 ? uint128(a) : 0;
    }

    function _lt(CTokenAmount memory a, CTokenAmount memory b) pure internal returns (bool) {
        return a.val < b.val;
    }

    function _lte(CTokenAmount memory a, CTokenAmount memory b) pure internal returns (bool) {
        return a.val <= b.val;
    }

    function _gt(CTokenAmount memory a, CTokenAmount memory b) pure internal returns (bool) {
        return a.val > b.val;
    }

    function _add(Exp memory a, Exp memory b) pure internal returns (Exp memory) {
        return Exp({mantissa: _add(a.mantissa, b.mantissa)});
    }

    function _add(CTokenAmount memory a, CTokenAmount memory b) pure internal returns (CTokenAmount memory) {
        return CTokenAmount({val: _add(a.val, b.val)});
    }

    function _add(uint128 a, uint128 b) pure internal returns (uint128) {
        uint128 c = a + b;
        require(c >= a, "addition overflow");
        return c;
    }

    function _sub(Exp memory a, Exp memory b) pure internal returns (Exp memory) {
        return Exp({mantissa: _sub(a.mantissa, b.mantissa)});
    }

    function _subToZero(CTokenAmount memory a, CTokenAmount memory b) pure internal returns (CTokenAmount memory) {
        if (b.val >= a.val) {
            return CTokenAmount({val: 0});
        } else {
            return _sub(a,b);
        }
    }

    function _sub(CTokenAmount memory a, CTokenAmount memory b) pure internal returns (CTokenAmount memory) {
        return CTokenAmount({val: _sub(a.val, b.val)});
    }

    function _sub(uint128 a, uint128 b) pure internal returns (uint128) {
        require(b <= a, "subtraction underflow");
        return a - b;
    }

    function _sub(int128 a, uint128 b) pure internal returns (int128) {
        int128 c = a - int128(b);
        require(a >= c, "int128 - uint128 underflow");
        return c;
    }

    function _add(int128 a, uint128 b) pure internal returns (int128) {
        int128 c = a + int128(b);
        require(a <= c, "int128 + uint128 overflow");
        return c;
    }

    function _mul(uint128 a, CTokenAmount memory b) pure internal returns (uint128) {
        return _mul(a, b.val);
    }

    function _mul(CTokenAmount memory a, uint128 b) pure internal returns (CTokenAmount memory) {
        return CTokenAmount({val: _mul(a.val, b)});
    }

    function _mul(Exp memory a, Exp memory b) pure internal returns (Exp memory) {
        return Exp({mantissa: _mul(a.mantissa, b.mantissa) / EXP_SCALE});
    }

    function _mul(Exp memory a, uint128 b) pure internal returns (Exp memory) {
        return Exp({mantissa: _mul(a.mantissa, b)});
    }

    function _mul(uint128 a, Exp memory b) pure internal returns (uint128) {
        return _mul(a, b.mantissa) / EXP_SCALE;
    }

    function _mul(uint128 a, uint128 b) pure internal returns (uint128) {
        if (a == 0 || b == 0) {
            return 0;
        }
        uint128 c = a * b;
        require(c / a == b, "multiplication overflow");
        return c;
    }

    function _div(uint128 a, CTokenAmount memory b) pure internal returns (uint128) {
        return _div(a, b.val);
    }

    function _div(CTokenAmount memory a, uint128 b) pure internal returns (CTokenAmount memory) {
        return CTokenAmount({val: _div(a.val, b)});
    }

    function _div(Exp memory a, Exp memory b) pure internal returns (Exp memory) {
        return Exp({mantissa: _div(_mul(a.mantissa, EXP_SCALE), b.mantissa)});
    }

    function _div(Exp memory a, uint128 b) pure internal returns (Exp memory) {
        return Exp({mantissa: _div(a.mantissa, b)});
    }

    function _div(uint128 a, Exp memory b) pure internal returns (uint128) {
        return _div(_mul(a, EXP_SCALE), b.mantissa);
    }

    function _div(uint128 a, uint128 b) pure internal returns (uint128) {
        require(b > 0, "divide by zero");
        return a / b;
    }

    function _min(Exp memory a, Exp memory b) pure internal returns (Exp memory) {
        return a.mantissa < b.mantissa ? a : b;
    }

    function _max(Exp memory a, Exp memory b) pure internal returns (Exp memory) {
        return a.mantissa > b.mantissa ? a : b;
    }

}
