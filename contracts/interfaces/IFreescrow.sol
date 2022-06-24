// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.7;

interface IFreescrow {
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
  
  /// access denied! Expected `expected`, but found `found`.
  /// @param expected address expected can perform the operation.
  /// @param found address attemp to perform the operation.
  error AccessDenied(address expected, address found);
  /// unexpected status! Expected `expected`, but current state `current`.
  /// @param expected expected status on this state.
  /// @param current current status on this state.
  error UnexpectedStatus(State expected, State current);
  /// Insufficient deposit for perform an operation. Needed `required` but only
  /// `available` available.
  /// @param available balance available.
  /// @param required requested amount to transfer.
  error InsufficientDeposit(uint256 available, uint256 required);
  /// invalid given address!
  error InvalidAddress();
  /// duration is invalid!
  error InvalidDuration();
  /// current timestamp `current` has been pass deadline `deadline`!
  /// @param current current timestamp.
  /// @param deadline expected deadline.
  error PassDeadline(uint256 current, uint256 deadline);
  /// current timestamp `current` has not been pass expected timestamp `deadline`!
  /// @param current current timestamp.
  /// @param expected expected timestamp.
  error TooEarly(uint256 current, uint256 expected);
  /// given input `given` is over maximum: `max`!
  /// @param given given input.
  /// @param max expected maximum.
  error OverMaximum(uint256 given, uint256 max);
  /// given input `given` is below minimum: `min`!
  /// @param given given input.
  /// @param min expected minimum.
  error BelowMinimum(uint256 given, uint256 min);
  /// given index is invalid!
  error InvalidIndex();
  /// fee is not yet deposited!
  error NotYetDeposited();

  event FundDeposited(uint256 fund, uint256 block);
  event AuctionStarted(uint256 duration, uint256 minBidAllowance);
  event BidPlaced(address indexed bidder, uint256 bid);
  event AuctionEnded();
  event WorkDeliverd(uint256 deliveredAt);
  event WorkVerified(uint256 block);
  event PaymentSettled(uint256 amount, address indexed recipient);
  event FundReclaimed(uint256 amount);
  event PaymentResolved(uint256 clientSettlementAmount, uint256 freelancerSettlementAmount);
  event DisputeFeeDeposited(address indexed who, uint256 amount);
  event DisputeFeeTimeout(address indexed who, uint256 when);
  event DisputeCreated(uint256 when);
}