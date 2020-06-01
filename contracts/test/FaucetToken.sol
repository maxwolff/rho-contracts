pragma solidity ^0.5.12;

import "../SafeMath.sol";
import "../StandardToken.sol";

contract FaucetToken is StandardToken {
    string public name;
    string public symbol;
    uint8 public decimals;

    constructor(uint256 _initialAmount, string memory _tokenName, uint8 _decimalUnits, string memory _tokenSymbol) public {
        totalSupply_ = _initialAmount;
        balances[msg.sender] = _initialAmount;
        name = _tokenName;
        symbol = _tokenSymbol;
        decimals = _decimalUnits;
    }

    function allocateTo(address _owner, uint256 value) public {
        balances[_owner] += value;
        totalSupply_ += value;
        emit Transfer(address(this), _owner, value);
    }
}
