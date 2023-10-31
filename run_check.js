const ethers = require('ethers')
require('dotenv').config()
const { Euler } = require("@eulerxyz/euler-sdk")

const provider = new ethers.providers.getDefaultProvider('http://127.0.0.1:8545/')
const signer = new ethers.Wallet(process.env.PRIVATE_KEY, provider)
const e = new Euler(signer)


async function getAccountdetailedLiquidity(address) {
    let detLiq = await e.contracts.exec.callStatic.detailedLiquidity(address);
    let totalLiabilities = ethers.BigNumber.from(0);
    let totalAssets = ethers.BigNumber.from(0);
    for (let asset of detLiq) {
        totalLiabilities = totalLiabilities.add(asset.status.liabilityValue);
        totalAssets = totalAssets.add(asset.status.collateralValue);
    }
    console.log("==================================")
    console.log("totalLiabilities", Number(totalLiabilities))
    console.log("totalAssets", Number(totalAssets))
    console.log("HealthScore", Number(totalAssets) / Number(totalLiabilities))
}



async function checkLiquidation(liquidator,violater,underlying,collateral) {
    const liquidationOpportunity = await e.contracts.liquidation.callStatic.checkLiquidation(
        liquidator,
        violater,
        underlying,
        collateral

    )
    console.log("====================")
    console.log("healthScore", liquidationOpportunity.healthScore / 1e18)
    console.log("yield", liquidationOpportunity.yield / 1e18)
    console.log("repay", liquidationOpportunity.repay / 1e18)
    console.log("baseDiscount", liquidationOpportunity.baseDiscount / 1e18)
    console.log("discount", liquidationOpportunity.discount / 1e18)
    console.log("conversionRate", liquidationOpportunity.conversionRate / 1e18)
    console.log("====================")
}

async function getPrice(address){
    const price = await e.contracts.exec.callStatic.getPrice(address)
    console.log("price", Number(price.twap))
}



async function main(){
    //不同token
    await getAccountdetailedLiquidity("0x513990A873C83DeE4a7122ce48175FF71CB0a68b")
    await checkLiquidation("0xb1ae6893d748db81b7f53494e19d9fda39ba25a7","0x513990A873C83DeE4a7122ce48175FF71CB0a68b","0xd9Fcd98c322942075A5C3860693e9f4f03AAE07b","0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0")

    //相同token
    // await getAccountdetailedLiquidity("0x2ec7641df0eff8659644c0f44199b0522e4232fb")
    // await checkLiquidation("0xb1ae6893d748db81b7f53494e19d9fda39ba25a7","0x2ec7641df0eff8659644c0f44199b0522e4232fb","0x6B175474E89094C44Da98b954EedeAC495271d0F","0x6B175474E89094C44Da98b954EedeAC495271d0F")
}

main()