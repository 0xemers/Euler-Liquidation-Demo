const { Euler } = require("@eulerxyz/euler-sdk")//用的euler的sdk，不像dydx直接创建合约对象调用proxy的liquidate()，因为proxy合约的保护
const ethers = require('ethers')
// const ethers = require('@nomiclabs/hardhat-ethers');
const hre = require("hardhat");
let c1e18 = ethers.BigNumber.from(10).pow(18)

require('dotenv').config()
const provider = new ethers.providers.getDefaultProvider('http://127.0.0.1:8545/')

let violator = "0x2ec7641df0eff8659644c0f44199b0522e4232fb"
let underlying = "0x6B175474E89094C44Da98b954EedeAC495271d0F"
let collateral = "0x6B175474E89094C44Da98b954EedeAC495271d0F"


async function unlockAccount(address) {
    await hre.network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [address],
    });
}

async function setBalance(address, amount) {
    await hre.network.provider.request({
        method: "hardhat_setBalance",
        params: [address, ethers.utils.parseEther(amount).toHexString()],
    })
}

async function getBalance(address) {
    let balance = await provider.getBalance(address)
    balance = ethers.utils.formatEther(balance)
    console.log("Wallet Address", address, "Wallet Balance", balance)
}

async function demo(signer, e) {
    let violator = "0x2ec7641df0eff8659644c0f44199b0522e4232fb"
    let underlying = "0x6B175474E89094C44Da98b954EedeAC495271d0F"
    let collateral = "0x6B175474E89094C44Da98b954EedeAC495271d0F"
    let liquidationOpportunity = await e.contracts.liquidation.callStatic.checkLiquidation(
        signer._address,
        violator,
        underlying,
        collateral
    )//compute liqopp
    console.log("====================")
    console.log("healthScore", liquidationOpportunity.healthScore / 1e18)
    console.log("yield", liquidationOpportunity.yield / 1e18)
    console.log("repay", liquidationOpportunity.repay / 1e18)
    console.log("baseDiscount", liquidationOpportunity.baseDiscount / 1e18)
    console.log("discount", liquidationOpportunity.discount / 1e18)
    console.log("conversionRate", liquidationOpportunity.conversionRate / 1e18)
    console.log("====================")

    let EToken = await initTokenContract(e)//初始化token contract

    const batchItems = [
        {
            contract: 'liquidation',
            method: 'liquidate',
            args: [
                violator,
                underlying,
                collateral,
                '0x152d02c7e14af6000000',
                0,
            ],
        },
        {
            contract: EToken,
            method: 'burn',
            args: [
                0,
                ethers.constants.MaxUint256,
            ],
        },
        {
            contract: 'markets',
            method: 'exitMarket',
            args: [
                0,
                underlying,
            ],
        }
    ]

    // console.log(batchItems)


    console.log("BuildBatch", await e.buildBatch(batchItems))
    console.log("Address",signer._address)
    const rawResults = await e.contracts.exec.batchDispatch(await e.buildBatch(batchItems), [signer._address])//调用Exec合约的批处理函数，把三个tx打包成一个tx
    console.log("RawResults",rawResults)
    const batchResults = e.decodeBatch(batchItems, rawResults)
    console.log("BatchResults",batchResults)



    liquidationOpportunity = await e.contracts.liquidation.callStatic.checkLiquidation(
        signer._address,
        violator,
        underlying,
        collateral
    )

    console.log("====================")
    console.log("healthScore",liquidationOpportunity.healthScore/1e18)
    console.log("yield",liquidationOpportunity.yield/1e18)
    console.log("repay",liquidationOpportunity.repay/1e18)
    console.log("baseDiscount",liquidationOpportunity.baseDiscount/1e18)
    console.log("discount",liquidationOpportunity.discount/1e18)
    console.log("conversionRate",liquidationOpportunity.conversionRate/1e18)
    console.log("====================")
}

async function underlyingToEtoken(ctx, addr) {
    let eTokenAddr = await ctx.contracts.markets.underlyingToEToken(addr);
    return await hre.ethers.getContractAt('EToken', eTokenAddr);
}


async function initTokenContract(ctx){
    let detLiq = await ctx.contracts.exec.callStatic.detailedLiquidity(violator);
    // console.log("DETliq", detLiq)
    let markets = [];

    let totalLiabilities = ethers.BigNumber.from(0);
    let totalAssets = ethers.BigNumber.from(0);

    for (let asset of detLiq) {
        let addr = asset.underlying.toLowerCase();
        let token = await hre.ethers.getContractAt('IERC20', addr);
        let decimals = await token.decimals();
        let sym = await token.symbol();

        let eToken = await underlyingToEtoken(ctx, addr);

        totalLiabilities = totalLiabilities.add(asset.status.liabilityValue);
        totalAssets = totalAssets.add(asset.status.collateralValue);

        markets.push({ addr, sym, decimals, eToken, status: asset.status, });
    };

    let underlyings = markets.filter(m => !m.status.liabilityValue.eq(0));
    let collaterals = markets.filter(m => !m.status.collateralValue.eq(0));
    
    return underlyings[0].eToken

}



async function main() {
    const address = "0xb1ae6893d748db81b7f53494e19d9fda39ba25a7" //清算人账户
    await unlockAccount(address)//解锁清算人账户
    const signer = await provider.getSigner(address)//拿到清算人账户
    const e = new Euler(signer);//初始化Euler对象，也就是调用SDK
    // // console.log(e.contracts.liquidation.callStatic)
    // // await getBalance(signer._address)
    // // await setBalance("0x4609F29Ea40a78196dCbc7EA54dAB8a02518984a","20.0")
    await demo(signer, e)//执行demo函数，入参是清算人地址和euler对象
    // // await getBalance("0x4609F29Ea40a78196dCbc7EA54dAB8a02518984a")



}

main()