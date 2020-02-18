pragma solidity ^0.5.12;

import "./IERC20.sol";
import "./SafeMath.sol";
import "./InterestRateModel.sol";


contract CTokenInterface {
	uint public borrowIndex;
}

contract Rho {

	using SafeMath for *;

	InterestRateModelInterface interestRateModel;
	CTokenInterface benchmarkCToken;
	IERC20 underlying;

	uint lastAccrualTime;
	uint currentSupplyIndex;
	uint totalLiquidity;

	uint benchmarkIndex;

	mapping(address => Account) accounts;

	struct Account {
		uint amount;
		uint lastDepositTime;
		uint lastSupplyIndex;
	}

	constructor (InterestRateModelInterface interestRateModel_, CTokenInterface benchmarkCToken_, IERC20 underlying_) public {
		interestRateModel = interestRateModel_;
		benchmarkCToken = benchmarkCToken_;
		underlying = underlying;
	}

	function supplyLiquidity(uint supplyAmount) public {
		// Accrue profits, updating supplyIndex so we know how much the provider has earned
		accrueProtocolCashflow();
		lastAccrualTime = block.timestamp;
		Account storage account = accounts[msg.sender];

		uint truedUpLiquidity = 0;
		if (account.amount != 0) {
			truedUpLiquidity = account.amount.mul(currentSupplyIndex).div(account.lastSupplyIndex);
		}

		account.amount = truedUpLiquidity.add(supplyAmount);
		account.lastDepositTime = block.timestamp;
		account.lastSupplyIndex = currentSupplyIndex;
	
		totalLiquidity = totalLiquidity.add(supplyAmount);
		benchmarkIndex = getBenchmarkIndex();

		underlying.transferFrom(msg.sender, address(this), supplyAmount);
	}

	function getBenchmarkIndex() public view returns (uint) {
		return benchmarkCToken.borrowIndex();
	}

	// function removeLiquidity(uint withdrawAmount) public {

	// }

	// function openPayFixedSwap(uint notionalAmount) public {

	// }

	// function openReceiveFixedSwap(uint notionalAmount) public {

	// }

	// function closeSwap(uint orderNumber) public {

	// }

	function accrueProtocolCashflow() public {
		uint accruedTime = block.timestamp - lastAccrualTime;
	}

	// function updateProtocolActiveCollateral() public {

	// }


	// function setInterestRateModel() {}

	// function updateCollateralRequirements(){}


}