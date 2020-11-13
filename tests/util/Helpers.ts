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

const MAX_UINT = bn(2).pow(256).sub(1).toHexString();

const hashEncode = (args) => {
	const web3 = new (require('web3'))();
	let str = web3.eth.abi.encodeParameters(['bool', 'uint256', 'uint256', 'uint256', 'uint256', 'uint256', 'address'], args);
	return web3.utils.keccak256(str);
}

const sendRPC = (method, params, saddle) => {
  return new Promise((resolve, reject) => {
    if (!saddle.web3.currentProvider || typeof (saddle.web3.currentProvider) === 'string') {
      return reject(`cannot send from currentProvider=${saddle.web3.currentProvider}`);
    }

    saddle.web3.currentProvider.send(
      {
        jsonrpc: '2.0',
        method: method,
        params: params,
        id: new Date().getTime()
      },
      (err, response) => {
        if (err) {
          reject(err);
        } else {
          resolve(response);
        }
      }
    );
  });
};

module.exports = {
	bn,
	str,
	mantissa,
	hashEncode,
	sendRPC, 
  MAX_UINT
};
