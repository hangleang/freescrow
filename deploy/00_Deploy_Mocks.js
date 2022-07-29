const { getNamedAccounts, deployments, network } = require("hardhat")
const { verify } =  require('../helper-functions')
const {
  developmentChains,
} = require("../helper-hardhat-config")

module.exports = async ({ getNamedAccounts, deployments, getChainId }) => {
  const { deploy, log } = deployments
  const { deployer } = await getNamedAccounts()
  // If we are on a local development network, we need to deploy mocks!

  log("----------------------------------------------------")
  log("Deploying Mock Arbitrator...")
  const arbitratorMock = await deploy("SimpleCentralizedArbitrator", {
    from: deployer,
    log: true,
    args: [],
  });
  const args = [
    "sample project",
    "description",
    1800,
    arbitratorMock.address,
    "0x",
    1800,
  ];
  const freescrowMock = await deploy("Freescrow", {
    from: deployer,
    log: true,
    args: args,
  });
  log("Mocks Deployed!")
  // log("----------------------------------------------------")
  // log("You are deploying to a local network, you'll need a local network running to interact")
  // log("Please run `yarn hardhat console` to interact with the deployed smart contracts!")
  // log("----------------------------------------------------")

  // Verify the deployment
  if (!developmentChains.includes(network.name) && process.env.ETHERSCAN_API_KEY) {
    log("Verifying...")
    await verify(arbitratorMock.address, [])
    await verify(freescrowMock.address, args)
  }
}
module.exports.tags = ["all", "mocks"]
