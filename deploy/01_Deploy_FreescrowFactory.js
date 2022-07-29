const { getNamedAccounts, deployments, network, run } = require("hardhat")
const {
  developmentChains,
} = require("../helper-hardhat-config")
const { verify } = require("../helper-functions")

module.exports = async ({ getNamedAccounts, deployments }) => {
  const { deploy, log } = deployments
  const { deployer } = await getNamedAccounts()
  
  log("----------------------------------------------------")
  log("Deploying Freescrow Factory...")
  const freescrowFactory = await deploy("FreescrowFactory", {
    from: deployer,
    args: [],
    log: true,
  })

  // Verify the deployment
  if (!developmentChains.includes(network.name) && process.env.ETHERSCAN_API_KEY) {
    log("Verifying...")
    await verify(freescrowFactory.address, [])
  }
}

module.exports.tags = ["all", "freescrow-factory"]
