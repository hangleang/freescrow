// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.7;

interface IFreescrow {
  error UnexpectedStatus();
  error ReleasedTooEarly();
  /// access denied! Expected `expected` found `found`.
  /// @param found address attemp to perform the operation.
  /// @param expected address expected can perform the operation.
  error AccessDenied(address found, address expected);
}