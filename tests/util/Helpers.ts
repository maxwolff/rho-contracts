const BigNumber = require("bignumber.js");
const ethers = require("ethers");

// web3 bn fiasco: https://github.com/ethereum/web3.js/issues/2077
const bn = num => {
	return ethers.utils.bigNumberify(new BigNumber(num).toFixed());
};

const str = num => {
	return bn(num).toHexString();
};

const mantissa = num => {
  return ethers.utils.bigNumberify(new BigNumber(num).times(1e18).toFixed());
}

const hashEncode = (args) => {
	const web3 = new (require('web3'))();
	let str = web3.eth.abi.encodeParameters(['bool', 'uint256', 'uint256', 'uint256', 'uint256', 'uint256', 'address'], args);
	return web3.utils.keccak256(str);
}

module.exports = {
	bn,
	str,
	mantissa,
	hashEncode
};
