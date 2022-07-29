const { getNamedAccounts, deployments, network } = require("hardhat")
const {
  developmentChains,
} = require("../helper-hardhat-config")

module.exports = async ({ getNamedAccounts, deployments, getChainId }) => {
  const { deploy, log } = deployments
  const { deployer } = await getNamedAccounts()
  // If we are on a local development network, we need to deploy mocks!

  log("----------------------------------------------------")
  log("Deploying Mock Arbitrator...")
  const mock = await deploy("SimpleCentralizedArbitrator", {
    from: deployer,
    log: true,
    args: [],
  })
  log("Mocks Deployed!")
  // log("----------------------------------------------------")
  // log("You are deploying to a local network, you'll need a local network running to interact")
  // log("Please run `yarn hardhat console` to interact with the deployed smart contracts!")
  // log("----------------------------------------------------")

  // Verify the deployment
  if (!developmentChains.includes(network.name) && process.env.ETHERSCAN_API_KEY) {
    log("Verifying...")
    await verify(mock.address, [])
  }
}
module.exports.tags = ["all", "mocks"]
