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

	function getHypotheticalOrderInfo(bool userPayingFixed, uint notionalAmount) external view returns (uint swapFixedRateMantissa, uint userCollateralCTokens) {
		(CTokenAmount memory lockedCollateral, CTokenAmount memory supplierLiquidity) = getSupplyCollateralState();
		(Exp memory swapFixedRate,) = rho.getSwapRate(userPayingFixed, notionalAmount, lockedCollateral, supplierLiquidity);

		CTokenAmount memory userCollateral;
		if (userPayingFixed) {
			userCollateral = rho.getPayFixedInitCollateral(swapFixedRate, notionalAmount);
			CTokenAmount memory lockedCollateralHypothetical = _add(lockedCollateral, rho.getReceiveFixedInitCollateral(swapFixedRate, notionalAmount));
			require(_lte(lockedCollateralHypothetical, supplierLiquidity), "Insufficient protocol collateral");
		} else {
			userCollateral = rho.getReceiveFixedInitCollateral(swapFixedRate, notionalAmount);
			CTokenAmount memory lockedCollateralHypothetical = _add(lockedCollateral, rho.getPayFixedInitCollateral(swapFixedRate, notionalAmount));
			require(_lte(lockedCollateralHypothetical, supplierLiquidity), "Insufficient protocol collateral");
		}
		return (swapFixedRate.mantissa, userCollateral.val);
	}

	function getSupplyCollateralState() public view returns (CTokenAmount memory lockedCollateral, CTokenAmount memory supplierLiquidity) {
		uint accruedBlocks = rho.getBlockNumber() - rho.lastAccrualBlock();
		(lockedCollateral,,) = rho.getLockedCollateral(accruedBlocks);

		Exp memory benchmarkIndexRatio = _div(_exp(rho.getBenchmarkIndex()), _exp(rho.benchmarkIndexStored()));
		Exp memory floatRate = _sub(benchmarkIndexRatio, _oneExp());

		supplierLiquidity = rho.getSupplierLiquidity(accruedBlocks, floatRate);
	}
}
