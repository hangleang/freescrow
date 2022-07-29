//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.7;

import "@kleros/erc-792/contracts/IArbitrator.sol";
import "./Freescrow.sol";

contract FreescrowFactory {
    event FreescrowCreated(address indexed arbitrator, address indexed wallet);

    address[] public freescrows;

    function create(
      address _owner,
      string memory _title,
      string memory _description,
      uint256 _durationInSeconds,
      IArbitrator _arbitrator,
      bytes memory _arbitratorExtraData,
      uint256 _arbitrationFeeDepositPeriod
    ) public returns (address freescrow) {
        freescrow = address(new Freescrow(
          _owner,
          _title, 
          _description, 
          _durationInSeconds, 
          _arbitrator, 
          _arbitratorExtraData,
          _arbitrationFeeDepositPeriod
        ));
        freescrows.push(freescrow);
        emit FreescrowCreated(address(_arbitrator), freescrow);
    }
}