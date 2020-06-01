const BigNumber = require("bignumber.js");
const ethers = require("ethers");

const sendCall = async (contract, opts = {}) => {
	const returnValue = await call(contract, opts);
	const res = await send(contract, opts);
	return returnValue;
};

const logSend = async (contract, fn, args, opts = {}) => {
	const eventDecoders = contract._jsonInterface
		.filter((i) => i.type == 'event')
		.reduce((acc, event) => {
			const { anonymous, inputs, signature } = event;
			return {
				...acc,
				[signature]: (log) => {
					let argTopics = anonymous
						? log.topics
						: log.topics.slice(1);
					return web3.eth.abi.decodeLog(inputs, log.data, argTopics);
				},
			};
		}, {});
	const result = await send(contract, fn, args, opts);
	const eventLogs = Object.values((result && result.events) || {}).reduce(
		(acc, event) => {
			const eventLog = event.raw;
			if (event.signature != undefined && eventLog) {
				const eventDecoder = eventDecoders[event.signature];
				if (eventDecoder) {
					const named = Object.entries(eventDecoder(eventLog)).filter((k,v)=>k[0].match(/[a-z]/i));
					return acc + `${event.event}: ${JSON.stringify(named)}\n`;
				} else {
					console.log('Couldnt find decoder');
					return acc + `${eventLog}\n`;
				}
			}
			return acc;
		},
		""
	);
	console.log('EMITTED EVENTS:   ', eventLogs);
	return result;
};

// https://github.com/ethereum/web3.js/issues/2077
const bn = num => {
	return ethers.utils.bigNumberify(new BigNumber(num).toFixed());
};

const mantissa = num => {
  return ethers.utils.bigNumberify(new BigNumber(num).times(1e18).toFixed());
}

const prep = async (spender, amount, token, who) => {
	await send(token, "allocateTo", [who, amount]);
	await send(token, "approve", [spender, amount], { from: who });
};

module.exports = {
	bn,
	sendCall,
	logSend,
	prep,
	mantissa
};
