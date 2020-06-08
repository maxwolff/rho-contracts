pragma solidity ^0.5.12;

contract Math {

	uint constant EXP_SCALE = 1e18;

	struct Exp {
    	uint mantissa;
    }

	/* always returns type of left side param */

    function _newExp(uint num) pure internal returns (Exp memory) {
    	return Exp({mantissa: num});
    }

    function _scaleToExp(uint num) pure internal returns (Exp memory) {
        return Exp({mantissa: _mul(EXP_SCALE, num)});
    }

    function _add(Exp memory a, Exp memory b) pure internal returns (Exp memory) {
        return Exp({mantissa: _add(a.mantissa, b.mantissa)});
    }

    function _add(uint a, uint b) pure internal returns (uint) {
        return _add(a, b, "addition overflow");
    }

    function _add(uint a, uint b, string memory errorMessage) pure internal returns (uint) {
        uint c = a + b;
        require(c >= a, errorMessage);
        return c;
    }

    function _sub(Exp memory a, Exp memory b) pure internal returns (Exp memory) {
        return Exp({mantissa: _sub(a.mantissa, b.mantissa)});
    }

    function _sub(uint a, uint b) pure internal returns (uint) {
        return _sub(a, b, "subtraction underflow");
    }

    function _sub(uint a, uint b, string memory errorMessage) pure internal returns (uint) {
        require(b <= a, errorMessage);
        return a - b;
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
        return _mul(a, b, "multiplication overflow");
    }

    function _mul(uint a, uint b, string memory errorMessage) pure internal returns (uint) {
        if (a == 0 || b == 0) {
            return 0;
        }
        uint c = a * b;
        require(c / a == b, errorMessage);
        return c;
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
        return _div(a, b, "divide by zero");
    }

    function _div(uint a, uint b, string memory errorMessage) pure internal returns (uint) {
        require(b > 0, errorMessage);
        return a / b;
    }

    function _min(Exp memory a, Exp memory b) pure internal returns (Exp memory) {
        return a.mantissa < b.mantissa ? a : b;
    }

    function _max(Exp memory a, Exp memory b) pure internal returns (Exp memory) {
        return a.mantissa > b.mantissa ? a : b;
    }

}
