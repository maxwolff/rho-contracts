
module.exports = {
  // solc: "solc",                                         // Solc command to run
  solc_args: [                                              // Extra solc args
    '--allow-paths','contracts',
    '--evm-version', 'istanbul'
  ],                                       // Extra solc args
  // build_dir: ".build",                                  // Directory to place built contracts
  contracts: "{contracts,contracts/**,contracts/test}/*.sol",   // Glob to match contract files
  solc_shell_args: {                                        // Args passed to `exec`, see:
    maxBuffer: 1024 * 500000,                               // https://nodejs.org/api/child_process.html#child_process_child_process_spawn_command_args_options
    shell: process.env['SADDLE_SHELL'] || '/bin/bash'
  },
  // build_dir: ".build",                                   // Directory to place built contracts
  extra_build_files: ['remote/*.json'],                     // Additional build files to deep merge
  // coverage_dir: "coverage",                              // Directory to place coverage files
  // coverage_ignore: [],                                   // List of files to ignore for coverage
  trace: false,
  tests: ['**/tests/*Test.ts'],                            // Glob to match test files
  networks: {                                           // Define configuration for each network
    development: {
      providers: [                                      // How to load provider (processed in order)
        {env: "PROVIDER"},                              // Try to load Http provider from `PROVIDER` env variable (e.g. env PROVIDER=http://...)
        {http: "http://127.0.0.1:8545"}                 // Fallback to localhost provider
      ],
      web3: {                                           // Web3 options for immediate confirmation in development mode
        gas: [
          {env: "GAS"},
          {default: "4600000"}
        ],
        gas_price: [
          {env: "GAS_PRICE"},
          {default: "12000000000"}
        ],
        options: {
          transactionConfirmationBlocks: 1,
          transactionBlockTimeout: 5
        }
      },
      accounts: [                                       // How to load default account for transactions
        {env: "ACCOUNT"},                               // Load from `ACCOUNT` env variable (e.g. env ACCOUNT=0x...)
        {unlocked: 0}                                   // Else, try to grab first "unlocked" account from provider
      ]
    },
    test: {
      providers: [
        {env: "PROVIDER"},
        {ganache: {}},                                  // In test mode, connect to a new ganache provider. Any options will be passed to ganache
      ],
      web3: {
        gas: [
          {env: "GAS"},
          {default: "4600000"}
        ],
        gas_price: [
          {env: "GAS_PRICE"},
          {default: "12000000000"}
        ],
        options: {
          transactionConfirmationBlocks: 1,
          transactionBlockTimeout: 5
        }
      },
      accounts: [
        {env: "ACCOUNT"},
        {unlocked: 0}
      ]
    }
  }
}
