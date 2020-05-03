const BigNumber = require("bignumber.js");
const ethers = require("ethers");
const util = require("util");

const sendCall = async (sendable, opts = {}) => {
	const returnValue = await call(sendable, opts);
	const res = await send(sendable, opts);
	return returnValue;
};

// added because web3 was weird about passing big numbers
// https://github.com/ethereum/web3.js/issues/2077
const bn = num => {
	return ethers.utils.bigNumberify(new BigNumber(num).toFixed());
};

const prep = async (spender, amount, token, who) => {
	await send(token, "allocateTo", [who, amount]);
	await send(token, "approve", [spender, amount], { from: who });
};

const mantissa = num => {
  return ethers.utils.bigNumberify(new BigNumber(num).times(1e18).toFixed());
}

module.exports = {
	bn,
	sendCall,
	prep,
	mantissa
};
