// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.6.10;

contract Types {

    /*@dev A type to store amounts of cTokens, to make sure they are not confused with amounts of the underlying */
    struct CTokenAmount {
        uint val;
    }

    /* @dev A type to store numbers scaled up by 18 decimals*/
    struct Exp {
        uint mantissa;
    }
}

/* Always returns type of left side param */
contract Math is Types {

	uint constant EXP_SCALE = 1e18;

    function _exp(uint num) pure internal returns (Exp memory) {
    	return Exp({mantissa: num});
    }

    function _oneExp() pure internal returns (Exp memory) {
        return Exp({mantissa: EXP_SCALE});
    }

    function _floor(int a) pure internal returns (uint) {
        return a > 0 ? uint(a) : 0;
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

    function _add(uint a, uint b) pure internal returns (uint) {
        uint c = a + b;
        require(c >= a, "addition overflow");
        return c;
    }

    function _sub(Exp memory a, Exp memory b) pure internal returns (Exp memory) {
        return Exp({mantissa: _sub(a.mantissa, b.mantissa)});
    }

    function _sub(CTokenAmount memory a, CTokenAmount memory b) pure internal returns (CTokenAmount memory) {
        return CTokenAmount({val: _sub(a.val, b.val)});
    }

    function _sub(uint a, uint b) pure internal returns (uint) {
        require(b <= a, "subtraction underflow");
        return a - b;
    }

    function _sub(int a, uint b) pure internal returns (int) {
        int c = a - int(b);
        require(a >= c, "int - uint underflow");
        return c;
    }

    function _add(int a, uint b) pure internal returns (int) {
        int c = a + int(b);
        require(a <= c, "int + uint overflow");
        return c;
    }

    function _mul(uint a, CTokenAmount memory b) pure internal returns (uint) {
        return _mul(a, b.val);
    }

    function _mul(CTokenAmount memory a, uint b) pure internal returns (CTokenAmount memory) {
        return CTokenAmount({val: _mul(a.val, b)});
    }

    function _mul(Exp memory a, Exp memory b) pure internal returns (Exp memory) {
        return Exp({mantissa: _mul(a.mantissa, b.mantissa) / EXP_SCALE});
    }

    function _mul(Exp memory a, uint b) pure internal returns (Exp memory) {
        return Exp({mantissa: _mul(a.mantissa, b)});
    }

    function _mul(uint a, Exp memory b) pure internal returns (uint) {
        return _mul(a, b.mantissa) / EXP_SCALE;
    }

    function _mul(uint a, uint b) pure internal returns (uint) {
        if (a == 0 || b == 0) {
            return 0;
        }
        uint c = a * b;
        require(c / a == b, "multiplication overflow");
        return c;
    }

    function _div(uint a, CTokenAmount memory b) pure internal returns (uint) {
        return _div(a, b.val);
    }

    function _div(CTokenAmount memory a, uint b) pure internal returns (CTokenAmount memory) {
        return CTokenAmount({val: _div(a.val, b)});
    }

    function _div(Exp memory a, Exp memory b) pure internal returns (Exp memory) {
        return Exp({mantissa: _div(_mul(a.mantissa, EXP_SCALE), b.mantissa)});
    }

    function _div(Exp memory a, uint b) pure internal returns (Exp memory) {
        return Exp({mantissa: _div(a.mantissa, b)});
    }

    function _div(uint a, Exp memory b) pure internal returns (uint) {
        return _div(_mul(a, EXP_SCALE), b.mantissa);
    }

    function _div(uint a, uint b) pure internal returns (uint) {
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
