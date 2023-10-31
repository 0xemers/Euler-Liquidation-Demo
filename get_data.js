const ethers = require('ethers')
require('dotenv').config()

const provider = new ethers.providers.getDefaultProvider('http://127.0.0.1:8545/')


const SimpleLens = '0xc2d41d42939109CDCfa26C6965269D9C0220b38E'
const SimpleLens_ABI = require('./abi/lens.json')


async function GetCurrentAccountValues(address){
    const SimpleLensContract = new ethers.Contract(SimpleLens, SimpleLens_ABI, provider)
    const accountStatus = await SimpleLensContract.getAccountStatus(address)
    console.log("Account HealthScore: ",Number(accountStatus.healthScore)/1e18)
    console.log("Account collateralValue: ",Number(accountStatus.collateralValue)/1e18)
    console.log("Account liabilityValue: ",Number(accountStatus.liabilityValue)/1e18)
}

async function main(){
    GetCurrentAccountValues("0x2ec7641df0eff8659644c0f44199b0522e4232fb")
}

main()