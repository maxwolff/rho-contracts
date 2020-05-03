const BigNumber = require('bignumber.js');
const { bn, mantissa } = require('./Helpers');

// let saddleSend = send;
// // log input, for testing
// send = (a, b, c, d) => {
//   console.log(b);
//   saddleSend(a, b, c, d);
// };

const msg = (actual, expected) => {
  return `Expected: ${JSON.stringify(expected)}, \n Actual: ${JSON.stringify(actual)}}`;
}

expect.extend({
  // untested
  toEqualNumber(expected, actual) {
    return {
      pass: bn(actual).eq(bn(expected)),
      message: () => msg(expected, expected),
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
    const actualBig = new BigNumber(actual.toString()).toPrecision(precision);
    const expectedBig = new BigNumber(expected.toString()).toPrecision(
      precision
    );
    return {
      pass: actualBig === expectedBig,
      message: () => msg(expectedBig, actualBig),
    };
  },
});
