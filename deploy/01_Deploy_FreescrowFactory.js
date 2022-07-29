const { getNamedAccounts, deployments, network, run } = require("hardhat")
const { verify } =  require('../helper-functions')
const {
  developmentChains,
  VERIFICATION_BLOCK_CONFIRMATIONS
} = require("../helper-hardhat-config")

module.exports = async ({ getNamedAccounts, deployments }) => {
  const { deploy, log } = deployments
  const { deployer } = await getNamedAccounts()
  const waitBlockConfirmations = developmentChains.includes(network.name)
    ? 1
    : VERIFICATION_BLOCK_CONFIRMATIONS

  log("----------------------------------------------------")
  log("Deploying Freescrow Factory...")
  const freescrowFactory = await deploy("FreescrowFactory", {
    from: deployer,
    args: [],
    log: true,
    waitConfirmations: waitBlockConfirmations,
  })

  // Verify the deployment
  if (!developmentChains.includes(network.name) && process.env.ETHERSCAN_API_KEY) {
    log("Verifying...")
    await verify(freescrowFactory.address, [])
  }
}

module.exports.tags = ["all", "freescrow-factory"]
