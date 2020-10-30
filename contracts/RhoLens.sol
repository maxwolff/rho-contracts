// SPDX-License-Identifier: GPL-3.0
pragma experimental ABIEncoderV2;
pragma solidity ^0.6.10;

import "./Rho.sol";
import "./Math.sol";

/* @dev A utility view contract */
contract RhoLensV1 is Math {

	Rho public immutable rho;

	constructor(Rho rho_) public {
		rho = rho_;
	}

	function getHypotheticalOrderInfo(bool userPayingFixed, uint notionalAmount) external view returns (uint swapFixedRateMantissa, uint userCollateralCTokens, uint userCollateralUnderlying, bool protocolIsCollateralized) {
		(CTokenAmount memory lockedCollateral, CTokenAmount memory supplierLiquidity, Exp memory cTokenExchangeRate) = getSupplyCollateralState();
		(Exp memory swapFixedRate,) = rho.getSwapRate(userPayingFixed, notionalAmount, lockedCollateral, supplierLiquidity, cTokenExchangeRate);
		protocolIsCollateralized = true;
		CTokenAmount memory userCollateral;
		if (userPayingFixed) {
			userCollateral = rho.getPayFixedInitCollateral(swapFixedRate, notionalAmount, cTokenExchangeRate);
			CTokenAmount memory lockedCollateralHypothetical = _add(lockedCollateral, rho.getReceiveFixedInitCollateral(swapFixedRate, notionalAmount, cTokenExchangeRate));
			if (_gt(lockedCollateralHypothetical, supplierLiquidity)) {
				protocolIsCollateralized = false;
			}
		} else {
			userCollateral = rho.getReceiveFixedInitCollateral(swapFixedRate, notionalAmount, cTokenExchangeRate);
			CTokenAmount memory lockedCollateralHypothetical = _add(lockedCollateral, rho.getPayFixedInitCollateral(swapFixedRate, notionalAmount, cTokenExchangeRate));
			if(_gt(lockedCollateralHypothetical, supplierLiquidity)) {
				protocolIsCollateralized = false;
			}
		}
		return (swapFixedRate.mantissa, userCollateral.val, toUnderlying(userCollateral.val), protocolIsCollateralized);
	}

	function getSupplyCollateralState() public view returns (CTokenAmount memory lockedCollateral, CTokenAmount memory supplierLiquidity, Exp memory cTokenExchangeRate) {
		cTokenExchangeRate = rho.getExchangeRate();

		uint accruedBlocks = rho.getBlockNumber() - rho.lastAccrualBlock();
		(lockedCollateral,,) = rho.getLockedCollateral(accruedBlocks, cTokenExchangeRate);

		Exp memory benchmarkIndexRatio = _div(rho.getBenchmarkIndex(), _exp(rho.benchmarkIndexStored()));
		Exp memory floatRate = _sub(benchmarkIndexRatio, ONE_EXP);

		supplierLiquidity = rho.getSupplierLiquidity(accruedBlocks, floatRate, cTokenExchangeRate);
	}

	function toUnderlying(uint cTokenAmt) public view returns (uint underlyingAmount) {
		Exp memory rate = rho.getExchangeRate();
		CTokenAmount memory amount = CTokenAmount({val: cTokenAmt});
		return rho.toUnderlying(amount, rate);
	}

	function toCTokens(uint underlyingAmount) public view returns (uint cTokenAmount) {
		Exp memory rate = rho.getExchangeRate();
		CTokenAmount memory amount = rho.toCTokens(underlyingAmount, rate);
		return amount.val;
	}

}
