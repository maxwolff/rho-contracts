const assert = require('assert');
const { str, bn, sendRPC, MAX_UINT } = require('../tests/util/Helpers.ts');
const CTokenABI = require('../script/cTokenABI.js').abi;

const deployProtocol = async (conf) => {
	const cToken = new web3.eth.Contract(CTokenABI, conf.cToken);

	const model = await deploy('InterestRateModel', [
		conf.yOffset,
		conf.slopeFactor,
		conf.rateFactorSensitivity,
		conf.feeBase,
		conf.feeSensitivity,
		conf.range
	]);

	const rho = await deploy('Rho',[
		model._address,
		conf.cToken,
		conf.comp,
		conf.minFloatMantissaPerBlock,
		conf.maxFloatMantissaPerBlock,
		conf.swapMinDuration,
		conf.supplyMinDuration,
		saddle.accounts[0],
		MAX_UINT
	]);
	assert(rho != undefined, "breokn here");
	const rhoLens = await deploy('RhoLensV1', [rho._address]);

	const approve = async (amt, who) => {
		await send(cToken, 'approve', [rho._address, amt], { from: who});
	}

	return {rho, rhoLens, model, cToken, approve};
};

const bnHex = (amt) => {
	return bn(parseInt(amt));
};

const getCloseArgs = (openTx) => {
	const vals = openTx.events.OpenSwap.returnValues;
	return [vals.userPayingFixed, vals.benchmarkIndexInit, vals.initBlock, vals.swapFixedRateMantissa, vals.notionalAmount, vals.userCollateralCTokens, vals.owner];
}

const mineBlocks = async (amt) => {
	let res = await sendRPC('eth_blockNumber', [], saddle);
	let bn = parseInt(res.result);
	await sendRPC('evm_mineBlockNumber', [bn + amt], saddle);
};

describe('Fork', () => {
	jest.setTimeout(20000);

	const conf = {
		yOffset: str(2.5e10),
		slopeFactor: str(0.5e36),
		range: str(4e10),
		rateFactorSensitivity: str(1e15),
		feeBase: str(5e9),
		feeSensitivity: str(3e9),

		minFloatMantissaPerBlock: str(0),
		maxFloatMantissaPerBlock: str(1e11),
		initExchangeRate: str(2e8),
		swapMinDuration: str(345600), // 60 days in blocks
		supplyMinDuration: str(172800), // 60 days in blocks
		comp: "0xc00e94cb662c3520282e6f5717214004a7f26888",
		cToken: "0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643"// cdai
	};

	let rho, rhoLens, model, cToken, approve;
	const [root, ...accts] = saddle.accounts;
	const [lp, a1, a2] = ["0x32B2D4ec46D76Fc6dAbfe958fb0e0BD8db740C84", "0x25599DCbd434aF9A17D52444f71c92987fa97cfC", "0x7d6149aD9A573A6E2Ca6eBf7D4897c1B766841B4"];

	const supplySizeUnderlying = bn(1e18);
	let supplySize;

	beforeAll(async () => {
		({rho, rhoLens, model, cToken, approve} = await deployProtocol(conf));

		supplySize = await call(rhoLens, 'toCTokens', [supplySizeUnderlying]);
		await approve(supplySize, lp);
		await send(rho, 'supply', [supplySize], {from: lp});
	});

	// rate begins at 4%, should increase with order size

	// rfNew = rfOld + sensitivity * orderSize / supplyUnderlying
	// 			0 +    7.5e13 *       100e18   /  1e18 = 7.5e15

	// baseRate = range * 	rf 	  / sqrt(rf^2 + slopeFac) + yOffset
	// 		   	  4e10 * 7.5e15 / (7.5e15 ^ 2 + 0.5e36) + 2.5e10

	it('open receive fixed', async () => {
		expect(await call(rho, 'supplierLiquidity', [])).toEqNum(supplySize);
		const orderSize = bn(100e18);

		const {swapFixedRateMantissa, userCollateralCTokens} = await call(rhoLens, 'getHypotheticalOrderInfo', [false, orderSize]);
		console.log(swapFixedRateMantissa, userCollateralCTokens);
		console.log(await call(rhoLens, 'toUnderlying', [userCollateralCTokens]));
		
		await approve(bn(30e8), a1);
		const openTx1 = await send(rho, 'openReceiveFixedSwap', [orderSize, bn(1e9)], {from: a1});
		console.log(openTx1.events.OpenSwap.returnValues);
		console.log(await call(rho, 'rateFactor', []));

		await mineBlocks(345601);
		const closeTx = await send(rho, 'close', getCloseArgs(openTx1));
		console.log(closeTx.events.CloseSwap.returnValues);
	});

});
