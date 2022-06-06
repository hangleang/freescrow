// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";

import "./interfaces/IFreescrow.sol";

// solhint-disable not-rely-on-time
contract Freescrow is Context, IArbitrable, IFreescrow {
  using SafeMath for uint256;

  enum State {
    /// Escrow has been initialized. waiting for PO deposit fund.
    Initialized,
    /// Fund has been deposited into contract. waiting for client to start auction project.
    PaymentInHold,
    /// Auction has been started. waiting for bid from freelancers.
    AuctionStarted,
    /// Auction has been completed, also Freelancer has been found. start working on the project.
    AuctionCompleted,
    /// Work has been delivered. waiting for verify from client.
    WorkDelivered,
    /// Work has been rejected, maybe freelancer missing something to deliver.
    WorkRejected,
    /// Client has been verified the work, Payment has been settled from contract to freelancer.
    VerifiedAndPaymentSettled,
    /// Arbitration fee deposited by either party.
    FeeDeposited,
    /// Dispute has been created.
    DisputeCreated,
    /// Dispute has been resolved.
    Resolved,
    /// Project has been closed and funds has been reclaimed by client,
    /// in case no bidding after auction or no work delivered after deadline.
    ReclaimNClosed
  }

  struct Bid {
    // who bid
    address participant;
    // how much
    uint256 amount;
  }

  struct Auction {
    /// all bids from participants
    Bid[] bids;
    /// ninimum for bid allowance
    uint256 minBid;
    /// timestamp of start auction
    uint256 startedAt;
    /// timestamp of end auction
    uint256 endAt;
  }

  // Arbitration
  enum RulingOption {
    /// split and send project fund equally to both parties (NOTES: bid deposit send to freelancer)
    RefusedToArbitrate, 
    /// settle all project fund + bid deposit to client
    Client, 
    /// settle all project fund + bid deposit to freelancer
    Freelancer 
  }

  enum Resolution {
    Executed,
    TimeoutByClient,
    TimeoutByFreelancer,
    RulingEnforced,
    SettlementReached
  }

  struct Dispute {
    uint256 disputeID;
    uint256 clientFee; // Total fees paid by the client.
    uint256 freelancerFee; // Total fees paid by the freelancer.
    RulingOption ruling;
    uint256 lastInteraction;
  }

  /// maximum verification period from client before fund can be release to freelancer
  uint256 public constant MAX_VERIFY_PERIOD = 2 days;
  /// title of freelance project
  string public title;
  /// some description goes here
  string public description;
  /// client address or project owner
  address payable public client = payable(_msgSender());
  /// freelancer address
  address payable public freelancer;
  /// deposited fund from client as project budget.
  uint256 public fund;
  /// state of payment
  State public state = State.Initialized;
  /// timestamp of start working on project
  uint256 public startedAt;
  /// timestamp of comfirm delivered project
  uint256 public deliveredAt;
  /// timestamp of project deadline (startedAt + duration), can extend a delay with penaty
  uint256 public deadline;
  /// project duration in seconds
  uint256 public immutable durationInSeconds;
  /// highest bid of last bid
  uint256 public highestBid;
  /// state of auction
  Auction public auction;

  // Arbitration
  uint8 public constant NUM_OF_CHOICES = 2;
  uint256 public immutable arbitrationFeeDepositPeriod;
  IArbitrator public immutable arbitrator;
  bytes public arbitratorExtraData;
  Dispute public dispute;

  constructor(
    string memory _title,
    string memory _description,
    uint256 _durationInSeconds,
    IArbitrator _arbitrator,
    bytes memory _arbitratorExtraData,
    uint256 _arbitrationFeeDepositPeriod
  ) checkDuration(_durationInSeconds) {
    title = _title;
    description = _description;
    durationInSeconds = _durationInSeconds;
    arbitrator = _arbitrator;
    arbitratorExtraData = _arbitratorExtraData;
    arbitrationFeeDepositPeriod = _arbitrationFeeDepositPeriod;
  }

  receive() external payable {
    deposit(0, 0);
  }

  // Mutation function

  function deposit(uint256 _minBid, uint256 auctionDuration)
    public
    payable
    onlyClient
    inState(State.Initialized)
  {
    fund = fund.add(msg.value);
    state = State.PaymentInHold;
    if (auctionDuration != 0) {
      startAuction(_minBid, auctionDuration);
    }
  }

  function startAuction(uint256 _minBid, uint256 auctionDuration)
    public
    onlyClient
    inState(State.PaymentInHold)
    checkDuration(auctionDuration)
  {
    require(_minBid < fund, "minimum bid is over project fund, auction can not start");
    auction.minBid = _minBid;
    auction.startedAt = block.timestamp;
    auction.endAt = block.timestamp.add(auctionDuration);
    state = State.AuctionStarted;
  }

  function placeBid() external payable inState(State.AuctionStarted) {
    require(block.timestamp < auction.endAt, "auction has been ended");
    uint256 bidAmount = msg.value;

    if (auction.bids.length == 0) {
      require(bidAmount > auction.minBid, "your bid is lower than minimum bid allowance");
    } else {
      Bid memory lastBid = auction.bids[auction.bids.length.sub(1)];
      require(bidAmount > lastBid.amount, "your bid is lower than previous bid");
      payable(lastBid.participant).transfer(lastBid.amount);
    }
    auction.bids.push(Bid({participant: _msgSender(), amount: bidAmount}));
  }

  function endAuction(uint256 _startedAt)
    external
    isClientOrFreelancer
    inState(State.AuctionStarted)
  {
    require(block.timestamp >= auction.endAt, "oop! no yet, be patient");
    if (auction.bids.length == 0) {
      state = State.PaymentInHold;
    } else {
      require(
        _startedAt == 0 || _startedAt >= block.timestamp,
        "start project can not before current timestamp"
      );
      if (_startedAt == 0) _startedAt = block.timestamp;
      startedAt = _startedAt;
      deadline = _startedAt.add(durationInSeconds);
      (address winner, uint256 amount) = getLastBid();
      freelancer = payable(winner);
      highestBid = amount;
      state = State.AuctionCompleted;
    }
  }

  function confirmDelivered() external onlyFreelancer inState(State.AuctionCompleted) {
    // check if current timestamp is before deadline of the project
    require(block.timestamp < deadline, "project has been reached deadline!");
    // freelancer delivered the work and confirmed the project has been done.
    deliveredAt = block.timestamp; // halt payment window countdown
    // then mark as WorkDelivered state
    state = State.WorkDelivered;
  }

  function verifyDelivered() external onlyClient inState(State.WorkDelivered) inVerifyDeadline {
    // client verified the project done and satisfied the work,
    // then settle project fund + deposit bid to freelancer,
    _settlePayment();
  }

  function rejectDelivered() external onlyClient inState(State.WorkDelivered) inVerifyDeadline {
    state = State.WorkRejected;
  }

  function releaseFunds() external onlyClient inState(State.WorkRejected) {
    // after project has been fully delivered, then client can process the payment to freelancer.
    _settlePayment();
  }

  function claimPayment() external inState(State.WorkDelivered) {
    require(block.timestamp - deliveredAt >= MAX_VERIFY_PERIOD, "oop! not yet, be patient");
    _settlePayment();
  }

  function reclaimFunds() external inState(State.AuctionCompleted) {
    require(block.timestamp >= deadline, "project not yet reach deadline.");
    _reclaimFunds();
  }

  function closeProject() public onlyClient inState(State.PaymentInHold) {
    // require(block.timestamp >= auction.endAt, "no yet, be patient");
    // require(auction.bids.length == 0, "");
    _reclaimFunds();
  }

  // Dispute procedure

  function depositArbitrationFee() external payable isClientOrFreelancer {
    require(
      state == State.WorkRejected || state == State.FeeDeposited, 
      "unexpected status!"
    );
    uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
    if (state == State.FeeDeposited) {
      require(block.timestamp - dispute.lastInteraction < arbitrationFeeDepositPeriod, "deposit arbitration fee timeout! waiting other party to claim the fund.");
    }

    if (_msgSender() == client) {
      dispute.clientFee += msg.value;
      require(dispute.clientFee >= arbitrationCost, "insufficient deposit fee");
    } else {
      dispute.freelancerFee += msg.value;
      require(dispute.freelancerFee >= arbitrationCost, "insufficient deposit fee");
    }
    dispute.lastInteraction = block.timestamp;

    if (dispute.clientFee >= arbitrationCost && dispute.freelancerFee >= arbitrationCost) {
      raiseDispute(arbitrationCost);
    } else {
      state = State.FeeDeposited;
    }
  }

  function timeOut() external inState(State.FeeDeposited) {
    require(block.timestamp - dispute.lastInteraction >= arbitrationFeeDepositPeriod, "timeout has not passed yet!");

    uint256 arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
    uint256 clientSettlementAmount = 0;
    uint256 freelancerSettlementAmount = 0;

    if (dispute.clientFee >= arbitrationCost) {
      clientSettlementAmount = fund.add(dispute.clientFee).add(highestBid);
    } else if (dispute.clientFee != 0) {
      clientSettlementAmount = dispute.clientFee;
    }

    if (dispute.freelancerFee >= arbitrationCost) {
      freelancerSettlementAmount = fund.add(dispute.freelancerFee).add(highestBid);
    } else if (dispute.freelancerFee != 0) {
      freelancerSettlementAmount = dispute.freelancerFee;
    }

    _resolvePayment(clientSettlementAmount, freelancerSettlementAmount);
  }

  function rule(uint256 _disputeID, uint256 _ruling) external override onlyArbitrator inState(State.DisputeCreated) {
    require(_ruling <= uint256(NUM_OF_CHOICES), "invalid ruling.");
    require(dispute.disputeID == _disputeID, "dispute does not exist.");
    dispute.ruling = RulingOption(_ruling);

    uint256 clientSettlementAmount = 0;
    uint256 freelancerSettlementAmount = 0;
    if (dispute.ruling == RulingOption.Client) {
      clientSettlementAmount = fund.add(dispute.clientFee).add(highestBid);
    } else if (dispute.ruling == RulingOption.Freelancer) {
      freelancerSettlementAmount = fund.add(dispute.freelancerFee).add(highestBid);
    } else {
      uint256 splitAmount = uint256(fund.add(dispute.clientFee).add(dispute.freelancerFee).add(highestBid)).div(2);
      clientSettlementAmount = splitAmount;
      freelancerSettlementAmount = splitAmount;
    }

    _resolvePayment(clientSettlementAmount, freelancerSettlementAmount);
    emit Ruling(arbitrator, _disputeID, _ruling);
  }

  // View function

  function getLastBid() public view returns (address participant, uint256 amount) {
    if (auction.bids.length == 0) {
      return (address(0), 0);
    }
    Bid memory lastBid = auction.bids[auction.bids.length.sub(1)];
    return (lastBid.participant, lastBid.amount);
  }

  function getBidsCount() public view returns (uint256 count) {
    return auction.bids.length;
  }

  function getBid(uint256 idx) public view returns (address participant, uint256 amount) {
    require(idx < auction.bids.length, "invalid given index!");
    Bid memory bid = auction.bids[idx];
    return (bid.participant, bid.amount);
  }

  function remainingAuctionPeriod() public view inState(State.AuctionStarted) returns (uint256) {
    return block.timestamp > auction.endAt
      ? 0
      : (auction.endAt - block.timestamp);
  }

  function remainingVerifyPeriod() public view inState(State.WorkDelivered) returns (uint256) {
    return (block.timestamp - deliveredAt) > MAX_VERIFY_PERIOD
      ? 0
      : (deliveredAt + MAX_VERIFY_PERIOD - block.timestamp);
  }

  function remainingDepositFeePeriod() public view returns (uint256) {
    require(dispute.lastInteraction > 0, "not count yet");
    return (block.timestamp - dispute.lastInteraction) > arbitrationFeeDepositPeriod
      ? 0
      : (dispute.lastInteraction + arbitrationFeeDepositPeriod - block.timestamp);
  }

  // Private & Internal function

  function raiseDispute(uint256 _arbitrationCost) internal {
    dispute.disputeID = arbitrator.createDispute{ value: _arbitrationCost }(
      NUM_OF_CHOICES,
      arbitratorExtraData
    );

    // Refund client if it overpaid
    uint256 extraClientFee = 0;
    if (dispute.clientFee > _arbitrationCost) {
      extraClientFee = dispute.clientFee - _arbitrationCost;
      dispute.clientFee = _arbitrationCost;
    } 

    // Refund freelancer if it overpaid
    uint256 extraFreelancerFee = 0;
    if (dispute.freelancerFee > _arbitrationCost) {
      extraFreelancerFee = dispute.freelancerFee - _arbitrationCost;
      dispute.freelancerFee = _arbitrationCost;
    } 

    state = State.DisputeCreated;
    if (extraClientFee > 0) client.transfer(extraClientFee);
    if (extraFreelancerFee > 0) freelancer.transfer(extraFreelancerFee);
  }

  function _settlePayment() private {
    // settle project fund + highestBid to freelancer,
    uint256 totalFunds = fund.add(highestBid);
    fund = 0;
    highestBid = 0;
    // then mark as VerifiedAndPaymentSettled state
    state = State.VerifiedAndPaymentSettled;
    freelancer.transfer(totalFunds);
  }

  function _reclaimFunds() private {
    fund = 0;
    highestBid = 0;
    // then mark as Reclaimed and Closed state
    state = State.ReclaimNClosed;
    client.transfer(address(this).balance);
  }

  function _resolvePayment(uint256 clientSettlementAmount, uint256 freelancerSettlementAmount) private {
    dispute.clientFee = 0;
    dispute.freelancerFee = 0;
    fund = 0;
    highestBid = 0;
    state = State.Resolved;

    if (clientSettlementAmount != 0) client.transfer(clientSettlementAmount);
    if (freelancerSettlementAmount != 0) freelancer.transfer(freelancerSettlementAmount);
  }

  // Modifiers (middleware)

  modifier onlyClient() {
    if (_msgSender() != client) {
      revert AccessDenied(_msgSender(), client);
    }
    _;
  }

  modifier onlyFreelancer() {
    if (_msgSender() != freelancer) {
      revert AccessDenied(_msgSender(), freelancer);
    }
    _;
  }

  modifier onlyArbitrator() {
    if (_msgSender() != address(arbitrator)) {
      revert AccessDenied(_msgSender(), address(arbitrator));
    }
    _;
  }

  modifier isClientOrFreelancer() {
    if (auction.bids.length == 0) {
      if (_msgSender() != client) {
        revert AccessDenied(_msgSender(), client);
      }
    } else {
      require(
        _msgSender() == client ||
            _msgSender() == auction.bids[auction.bids.length.sub(1)].participant,
        "access denied!"
      );
    }
    _;
  }

  modifier inState(State received) {
    if (state != received) {
      revert UnexpectedStatus();
    }
    _;
  }

  modifier checkDuration(uint256 duration) {
    require(duration != 0, "duration is invalid!");
    _;
  }

  modifier checkAddress(address who) {
    require(who != address(0), "invalid given address!");
    _;
  }

  modifier inVerifyDeadline() {
    require(block.timestamp - deliveredAt <= MAX_VERIFY_PERIOD, "verification has been reached deadline!");
    _;
  }
}
