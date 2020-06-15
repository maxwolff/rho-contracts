const BigNumber = require('bignumber.js');
const { bn, mantissa } = require('./Helpers');
let assert = require('assert');

// let saddleSend = deploy;
// // log input, for testing
// deploy = async (a, b, c, d) => {
//   try {
//     let f = await saddleSend(a, b, c, d);
//     assert(!!f, 'why undefined');
//     console.log(a,b);
//   } catch(e) {
//     throw e
//   };
// };

const msg = (expected, actual) => {
  return `Expected: ${JSON.stringify(expected.toString())}, \n Actual: ${JSON.stringify(actual.toString())}}`;
}

let i = 0;

expect.extend({
  toEqNum(expected, actual) {
    return {
      pass: bn(actual).eq(bn(expected)),
      message: () => msg(expected, actual),
    };
  },

  toRevert(trx, msg = 'revert') {
    return {
      pass: !!trx.message && trx.message === `VM Exception while processing transaction: revert ${msg}`,
      message: () => {
        if (trx.message) {
          return `expected VM Exception while processing transaction: ${msg}, got ${trx.message}`
        } else {
          return `expected revert, but transaction succeeded: ${JSON.stringify(trx)}`
        }
      }
    }
  },

  toAlmostEqual(expected, actual, precision) {
    const bnActual = new BigNumber(actual.toString()).toPrecision(precision);
    const bnExpected = new BigNumber(expected.toString()).toPrecision(
      precision
    );
    return {
      pass: bnActual === bnExpected,
      message: () => msg(bnExpected, bnActual),
    };
  },
});
