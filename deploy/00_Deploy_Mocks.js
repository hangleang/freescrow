const { getNamedAccounts, deployments, network } = require("hardhat")
const { verify } =  require('../helper-functions')
const {
  developmentChains,
  VERIFICATION_BLOCK_CONFIRMATIONS
} = require("../helper-hardhat-config")

module.exports = async ({ getNamedAccounts, deployments, getChainId }) => {
  const { deploy, log } = deployments
  const { deployer } = await getNamedAccounts()
  const waitBlockConfirmations = developmentChains.includes(network.name)
    ? 1
    : VERIFICATION_BLOCK_CONFIRMATIONS
  // If we are on a local development network, we need to deploy mocks!

  log("----------------------------------------------------")
  log("Deploying Mock Arbitrator...")
  const arbitratorMock = await deploy("SimpleCentralizedArbitrator", {
    from: deployer,
    log: true,
    args: [],
    waitConfirmations: waitBlockConfirmations,
  });
  // log("----------------------------------------------------")
  // log("You are deploying to a local network, you'll need a local network running to interact")
  // log("Please run `yarn hardhat console` to interact with the deployed smart contracts!")
  // log("----------------------------------------------------")

  // Verify the deployment
  if (!developmentChains.includes(network.name) && process.env.ETHERSCAN_API_KEY) {
    log("Verifying...")
    await verify(arbitratorMock.address, [])
  }
}
module.exports.tags = ["all", "mocks"]
