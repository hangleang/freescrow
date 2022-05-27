// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";

// solhint-disable not-rely-on-time
contract Freescrow is Context, IArbitrable {
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
    /// Dispute has been created.
    Disputed,
    /// Project has been closed, in case no bidding after auction.
    Closed
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
    uint256 startAt;
    /// timestamp of end auction
    uint256 endAt;
  }

  // Arbitration
  enum Party {
    None, // 0: split and send project fund equally to both parties (NOTES: bid deposit send to freelancer)
    Client, // 1: settle all product fund + bid deposit to client
    Freelancer // 2: 1: settle all product fund + bid deposit to freelancer
  }

  enum Resolution {
    None,
    DisputeCreated,
    RulingEnforced,
    Resolved
  }

  struct Dispute {
    uint256 disputeID;
    Party ruling;
  }

  /// maximum verification delay from client before fund can be release to freelancer
  uint256 public constant MAX_VERIFY_DELAY_IN_SECONDS = 2 days;
  /// title of freelance project
  string public title;
  /// some description goes here
  string public description;
  /// client address
  address payable public client = payable(_msgSender());
  /// freelancer address
  address payable public freelancer;
  /// deposited fund from client as project budget.
  uint256 public fund;
  /// state of payment
  State public state = State.Initialized;
  /// timestamp of start working on project
  uint256 public startAt;
  /// timestamp of comfirm delivered project
  uint256 public deliverAt;
  /// timestamp of project deadline (startAt + duration), can extend a delay with penaty
  uint256 public deadline;
  /// project duration in seconds
  uint256 public immutable durationInSeconds;
  /// highest bid of last bid
  uint256 public highestBid;
  /// state of auction
  Auction public auction;

  // Arbitration
  uint8 public constant AMOUNT_OF_CHOICES = 2;
  uint256 public immutable feeDepositTimeout;
  IArbitrator public immutable arbitrator;
  bytes public arbitratorExtraData;
  Dispute public dispute;
  Resolution public resolution;

  constructor(
    string memory _title,
    string memory _description,
    IArbitrator _arbitrator,
    bytes memory _arbitratorExtraData,
    uint256 _feeDepositTimeout,
    uint256 _durationInSeconds
  ) checkDuration(_durationInSeconds) {
    title = _title;
    description = _description;
    arbitrator = _arbitrator;
    arbitratorExtraData = _arbitratorExtraData;
    feeDepositTimeout = _feeDepositTimeout;
    durationInSeconds = _durationInSeconds;
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
    auction.startAt = block.timestamp;
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

  function endAuction(uint256 _startAt)
    external
    isClientOrFreelancer
    inState(State.AuctionStarted)
  {
    require(block.timestamp >= auction.endAt, "oop! no yet, be patient");
    if (auction.bids.length == 0) {
      state = State.PaymentInHold;
    } else {
      require(
        _startAt == 0 || _startAt >= block.timestamp,
        "start project can not before current timestamp"
      );
      if (_startAt == 0) _startAt = block.timestamp;
      startAt = _startAt;
      deadline = _startAt.add(durationInSeconds);
      (address winner, uint256 amount) = getLastBid();
      freelancer = payable(winner);
      highestBid = amount;
      state = State.AuctionCompleted;
    }
  }

  function closeProject() external onlyClient inState(State.PaymentInHold) {
    // require(block.timestamp >= auction.endAt, "no yet, be patient");
    // require(auction.bids.length == 0, "");
    state = State.Closed;
    client.transfer(fund);
  }

  function confirmDelivered() external onlyFreelancer inState(State.AuctionCompleted) {
    // check if current timestamp is before deadline of the project
    require(block.timestamp <= deadline, "project has been reached deadline!");
    // freelancer delivered the work and confirmed the project has been done.
    deliverAt = block.timestamp; // halt payment window countdown
    // then mark as WorkDelivered state
    state = State.WorkDelivered;
  }

  function verifyDelivered() external onlyClient inState(State.WorkDelivered) inVerifyDeadline {
    // client verified the project done and satisfied the work,
    // then settle project fund, highestBid to freelancer,
    _settlePayment();
  }

  function rejectDelivered() external onlyClient inState(State.WorkDelivered) inVerifyDeadline {
    state = State.WorkRejected;
  }

  function releaseFunds() external onlyClient inState(State.WorkRejected) {
    // after project has been fully delivered, then client can process the payment to freelancer.
    _settlePayment();
  }

  function claimPayment() external onlyFreelancer inState(State.WorkDelivered) {
    uint256 verifyDeadline = deliverAt.add(MAX_VERIFY_DELAY_IN_SECONDS);
    require(block.timestamp > verifyDeadline, "oop! not yet, be patient");
    _settlePayment();
  }

  function 

  function rule(uint256 _disputeID, uint256 _ruling) external override onlyArbitrator {
    require(_ruling <= uint256(AMOUNT_OF_CHOICES), "invalid ruling.");

    dispute = Dispute({
      disputeID: _disputeID,
      ruling: Party(_ruling)
    });
    require(dispute.disputeID == 0, "dispute already been solved.");
  }

  function createDispute() external isClientOrFreelancer {}

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

  // Private function

  function _settlePayment() private {
    // settle project fund + highestBid to freelancer,
    uint256 totalFunds = fund.add(highestBid);
    fund = 0;
    highestBid = 0;
    // then mark as VerifiedAndPaymentSettled state
    state = State.VerifiedAndPaymentSettled;
    freelancer.transfer(totalFunds);
  }

  // Modifiers (middleware)

  modifier onlyClient() {
    require(_msgSender() == client, "access denied!");
    _;
  }

  modifier onlyFreelancer() {
    require(_msgSender() == freelancer, "access denied!");
    _;
  }

  modifier onlyArbitrator() {
    require(_msgSender() == address(arbitrator), "the call must be the arbitrator.");
    _;
  }

  modifier isClientOrFreelancer() {
    if (auction.bids.length == 0) {
      require(_msgSender() == client, "access denied!");
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
    require(state == received, "unexpected status!");
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
    // check if current timestamp is before (deliverAt + max_verify_delay)
    uint256 verifyDeadline = deliverAt.add(MAX_VERIFY_DELAY_IN_SECONDS);
    require(block.timestamp <= verifyDeadline, "verification has been reached deadline!");
    _;
  }
}
