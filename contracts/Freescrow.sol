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
    uint256 firstDepositFeeAt;
  }

  /// maximum verification period from client before fund can be release to freelancer
  uint256 public constant MAX_VERIFY_PERIOD = 2 days;
  /// maximum verification period from client before fund can be release to freelancer
  uint256 public constant MAX_AUCTION_DURATION = 30 days;
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
    address _owner,
    string memory _title,
    string memory _description,
    uint256 _durationInSeconds,
    IArbitrator _arbitrator,
    bytes memory _arbitratorExtraData,
    uint256 _arbitrationFeeDepositPeriod
  ) checkDuration(_durationInSeconds) {
    client = payable(_owner);
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

  function deposit(uint256 _auctionDuration, uint256 _minBid)
    public
    payable
    onlyClient
    inState(State.Initialized)
  {
    fund = fund.add(msg.value);
    state = State.PaymentInHold;

    emit FundDeposited(fund, block.timestamp);
    if (_auctionDuration != 0) {
      startAuction(_auctionDuration, _minBid);
    }
  }

  function startAuction(uint256 _auctionDuration, uint256 _minBid)
    public
    onlyClient
    inState(State.PaymentInHold)
    checkDuration(_auctionDuration)
  {
    if (_auctionDuration > MAX_AUCTION_DURATION) {
      revert OverMaximum(_auctionDuration, MAX_AUCTION_DURATION);
    }
    if (_minBid >= fund) {
      revert OverMaximum(_minBid, fund);
    }
    auction.minBid = _minBid;
    auction.startedAt = block.timestamp;
    auction.endAt = block.timestamp.add(_auctionDuration);
    state = State.AuctionStarted;

    emit AuctionStarted(_auctionDuration, _minBid);
  }

  function placeBid() external payable inState(State.AuctionStarted) {
    if (block.timestamp > auction.endAt) {
      revert PassDeadline(block.timestamp, auction.endAt);
    }
    uint256 bidAmount = msg.value;

    auction.bids.push(Bid({participant: _msgSender(), amount: bidAmount}));
    if (auction.bids.length == 0) {
      if (bidAmount < auction.minBid) {
        revert BelowMinimum(bidAmount, auction.minBid);
      }
    } else {
      Bid memory lastBid = auction.bids[auction.bids.length.sub(1)];
      if (bidAmount < lastBid.amount) {
        revert BelowMinimum(bidAmount, lastBid.amount);
      }
      payable(lastBid.participant).transfer(lastBid.amount);
    }

    emit BidPlaced(_msgSender(), bidAmount);
  }

  function endAuction(uint256 _startedAt)
    external
    isClientOrFreelancer
    inState(State.AuctionStarted)
  {
    if (block.timestamp < auction.endAt) {
      revert TooEarly(block.timestamp, auction.endAt);
    }
    if (auction.bids.length == 0) {
      state = State.PaymentInHold;
    } else {
      if (_startedAt != 0 && _startedAt < block.timestamp) {
        revert TooEarly(block.timestamp, _startedAt);
      }
      if (_startedAt == 0) _startedAt = block.timestamp;
      startedAt = _startedAt;
      deadline = _startedAt.add(durationInSeconds);
      (address winner, uint256 amount) = getLastBid();
      freelancer = payable(winner);
      highestBid = amount;
      state = State.AuctionCompleted;
    }

    emit AuctionEnded();
  }

  function confirmDelivered() external onlyFreelancer inState(State.AuctionCompleted) {
    // check if current timestamp is before deadline of the project
    if (block.timestamp >= deadline) {
      revert PassDeadline(block.timestamp, deadline);
    }
    // freelancer delivered the work and confirmed the project has been done.
    deliveredAt = block.timestamp; // halt payment window countdown
    // then mark as WorkDelivered state
    state = State.WorkDelivered;

    emit WorkDeliverd(deliveredAt);
  }

  function verifyDelivered() external onlyClient inState(State.WorkDelivered) inVerifyPeriod {
    // client verified the project done and satisfied the work,
    // then settle project fund + deposit bid to freelancer,
    _settlePayment();
    emit WorkVerified(block.timestamp);
  }

  function rejectDelivered() external onlyClient inState(State.WorkDelivered) inVerifyPeriod {
    state = State.WorkRejected;
  }

  function releaseFunds() external onlyClient inState(State.WorkRejected) {
    // after project has been fully delivered, then client can process the payment to freelancer.
    _settlePayment();
  }

  function claimPayment() external inState(State.WorkDelivered) {
    uint256 expected = deliveredAt.add(MAX_VERIFY_PERIOD);
    if (block.timestamp < expected) {
      revert TooEarly(block.timestamp, expected);
    }
    _settlePayment();
  }

  function reclaimFunds() external inState(State.AuctionCompleted) {
    if (block.timestamp < deadline) {
      revert TooEarly(block.timestamp, deadline);
    }
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
    if (state == State.FeeDeposited && block.timestamp.sub(dispute.firstDepositFeeAt) > arbitrationFeeDepositPeriod) {
      revert PassDeadline(block.timestamp, dispute.firstDepositFeeAt.add(arbitrationFeeDepositPeriod));
    }

    if (_msgSender() == client) {
      dispute.clientFee += msg.value;
      if (dispute.clientFee < arbitrationCost) {
        revert InsufficientDeposit(dispute.clientFee, arbitrationCost);
      }
    } else {
      dispute.freelancerFee += msg.value;
      if (dispute.freelancerFee < arbitrationCost) {
        revert InsufficientDeposit(dispute.freelancerFee, arbitrationCost);
      }
    }

    if (dispute.clientFee >= arbitrationCost && dispute.freelancerFee >= arbitrationCost) {
      raiseDispute(arbitrationCost);
    } else {
      dispute.firstDepositFeeAt = block.timestamp;
      state = State.FeeDeposited;
    }

    emit DisputeFeeDeposited(_msgSender(), msg.value);
  }

  function timeOut() external inState(State.FeeDeposited) {
    if (block.timestamp.sub(dispute.firstDepositFeeAt) < arbitrationFeeDepositPeriod) {
      revert TooEarly(block.timestamp, (dispute.firstDepositFeeAt.add(arbitrationFeeDepositPeriod)));
    }

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

    emit DisputeFeeTimeout(_msgSender(), block.timestamp);
    _resolvePayment(clientSettlementAmount, freelancerSettlementAmount);
  }

  function rule(uint256 _disputeID, uint256 _ruling) external override onlyArbitrator inState(State.DisputeCreated) {
    if (_ruling > uint256(NUM_OF_CHOICES)) {
      revert OverMaximum(_ruling, uint256(NUM_OF_CHOICES));
    }
    if (_disputeID != dispute.disputeID) revert InvalidIndex();
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

    emit Ruling(arbitrator, _disputeID, _ruling);
    _resolvePayment(clientSettlementAmount, freelancerSettlementAmount);
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
    if (idx >= auction.bids.length) {
      revert InvalidIndex();
    }
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
    if (dispute.firstDepositFeeAt == 0) {
      revert NotYetDeposited();
    }
    return (block.timestamp - dispute.firstDepositFeeAt) > arbitrationFeeDepositPeriod
      ? 0
      : (dispute.firstDepositFeeAt + arbitrationFeeDepositPeriod - block.timestamp);
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

    emit DisputeCreated(block.timestamp);
  }

  function _settlePayment() private {
    // settle project fund + highestBid to freelancer,
    uint256 totalFunds = fund.add(highestBid);
    fund = 0;
    highestBid = 0;
    // then mark as VerifiedAndPaymentSettled state
    state = State.VerifiedAndPaymentSettled;
    freelancer.transfer(totalFunds);

    emit PaymentSettled(totalFunds, freelancer);
  }

  function _reclaimFunds() private {
    fund = 0;
    highestBid = 0;
    // then mark as Reclaimed and Closed state
    state = State.ReclaimNClosed;
    uint256 amount = address(this).balance;
    client.transfer(amount);

    emit FundReclaimed(amount);
  }

  function _resolvePayment(uint256 clientSettlementAmount, uint256 freelancerSettlementAmount) private {
    dispute.clientFee = 0;
    dispute.freelancerFee = 0;
    fund = 0;
    highestBid = 0;
    state = State.Resolved;

    if (clientSettlementAmount != 0) client.transfer(clientSettlementAmount);
    if (freelancerSettlementAmount != 0) freelancer.transfer(freelancerSettlementAmount);

    emit PaymentResolved(clientSettlementAmount, freelancerSettlementAmount);
  }

  // Modifiers (middleware)

  modifier onlyClient() {
    if (_msgSender() != client) {
      revert AccessDenied(client, _msgSender());
    }
    _;
  }

  modifier onlyFreelancer() {
    if (_msgSender() != freelancer) {
      revert AccessDenied(freelancer, _msgSender());
    }
    _;
  }

  modifier onlyArbitrator() {
    if (_msgSender() != address(arbitrator)) {
      revert AccessDenied(address(arbitrator), _msgSender());
    }
    _;
  }

  modifier isClientOrFreelancer() {
    if (auction.bids.length == 0) {
      if (_msgSender() != client) {
        revert AccessDenied(client, _msgSender());
      }
    } else {
      address lastParticipant = auction.bids[auction.bids.length.sub(1)].participant;
      require(_msgSender() == client || _msgSender() == lastParticipant, "access denied!");
    }
    _;
  }

  modifier inState(State expected) {
    if (state != expected) {
      revert UnexpectedStatus(expected, state);
    }
    _;
  }

  modifier checkDuration(uint256 duration) {
    if (duration == 0) {
      revert InvalidDuration();
    }
    _;
  }

  modifier checkAddress(address who) {
    if (who == address(0)) {
      revert InvalidAddress();
    }
    _;
  }

  modifier inVerifyPeriod() {
    if (block.timestamp - deliveredAt > MAX_VERIFY_PERIOD) {
      revert PassDeadline(block.timestamp, deliveredAt.add(MAX_VERIFY_PERIOD));
    }
    _;
  }
}
