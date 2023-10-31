require("hardhat-tracer");
require('@nomiclabs/hardhat-ethers');
require('dotenv').config()

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  solidity: {
    compilers: [
        {
            version: "0.8.10",
            settings: {
                optimizer: {
                    enabled: true,
                    runs: 1000000,
                },
                outputSelection: {
                    "contracts/Storage.sol": {
                        "*": [
                          "storageLayout",
                        ],
                    },
                },
            },
        },
    ],
},
  defaultNetwork: "hardhat",
  networks: {
    hardhat: {
      chainId: 31337,
      forking: {
        url: process.env.MAINNET_RPC_URL,
      },
    },
  }
};