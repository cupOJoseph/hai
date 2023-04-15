// SPDX-License-Identifier: GPL-3.0
/// DebtAuctionHouse.sol

// Copyright (C) 2018 Rain <rainbreak@riseup.net>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity 0.8.19;

import {ISAFEEngine as SAFEEngineLike} from '@interfaces/ISAFEEngine.sol';
import {IToken as TokenLike} from '@interfaces/external/IToken.sol';
import {IAccountingEngine as AccountingEngineLike} from '@interfaces/IAccountingEngine.sol';

import {Authorizable} from '@contracts/utils/Authorizable.sol';

import {Math, WAD} from '@libraries/Math.sol';

/*
   This thing creates protocol tokens on demand in return for system coins
*/

contract DebtAuctionHouse is Authorizable {
  // --- Data ---
  struct Bid {
    // Bid size
    uint256 bidAmount; // [rad]
    // How many protocol tokens are sold in an auction
    uint256 amountToSell; // [wad]
    // Who the high bidder is
    address highBidder;
    // When the latest bid expires and the auction can be settled
    uint48 bidExpiry; // [unix epoch time]
    // Hard deadline for the auction after which no more bids can be placed
    uint48 auctionDeadline; // [unix epoch time]
  }

  // Bid data for each separate auction
  mapping(uint256 => Bid) public bids;

  // SAFE database
  SAFEEngineLike public safeEngine;
  // Protocol token address
  TokenLike public protocolToken;
  // Accounting engine
  address public accountingEngine;

  // Minimum bid increase compared to the last bid in order to take the new one in consideration
  uint256 public bidDecrease = 1.05e18; // [wad]
  // Increase in protocol tokens sold in case an auction is restarted
  uint256 public amountSoldIncrease = 1.5e18; // [wad]
  // How long the auction lasts after a new bid is submitted
  uint48 public bidDuration = 3 hours; // [seconds]
  // Total length of the auction
  uint48 public totalAuctionLength = 2 days; // [seconds]
  // Number of auctions started up until now
  uint256 public auctionsStarted = 0;
  // Accumulator for all debt auctions currently not settled
  uint256 public activeDebtAuctions;
  uint256 public contractEnabled;

  bytes32 public constant AUCTION_HOUSE_TYPE = bytes32('DEBT');

  // --- Events ---
  event StartAuction(
    uint256 indexed id,
    uint256 auctionsStarted,
    uint256 amountToSell,
    uint256 initialBid,
    address indexed incomeReceiver,
    uint256 indexed auctionDeadline,
    uint256 activeDebtAuctions
  );
  event ModifyParameters(bytes32 parameter, uint256 data);
  event ModifyParameters(bytes32 parameter, address data);
  event RestartAuction(uint256 indexed id, uint256 auctionDeadline);
  event DecreaseSoldAmount(uint256 indexed id, address highBidder, uint256 amountToBuy, uint256 bid, uint256 bidExpiry);
  event SettleAuction(uint256 indexed id, uint256 activeDebtAuctions);
  event TerminateAuctionPrematurely(
    uint256 indexed id, address sender, address highBidder, uint256 bidAmount, uint256 activeDebtAuctions
  );
  event DisableContract(address sender);

  // --- Init ---
  constructor(address _safeEngine, address _protocolToken) {
    _addAuthorization(msg.sender);
    safeEngine = SAFEEngineLike(_safeEngine);
    protocolToken = TokenLike(_protocolToken);
    contractEnabled = 1;
    emit AddAuthorization(msg.sender);
  }

  // --- Admin ---
  /**
   * @notice Modify an uint256 parameter
   * @param parameter The name of the parameter modified
   * @param data New value for the parameter
   */
  function modifyParameters(bytes32 parameter, uint256 data) external isAuthorized {
    if (parameter == 'bidDecrease') bidDecrease = data;
    else if (parameter == 'amountSoldIncrease') amountSoldIncrease = data;
    else if (parameter == 'bidDuration') bidDuration = uint48(data);
    else if (parameter == 'totalAuctionLength') totalAuctionLength = uint48(data);
    else revert('DebtAuctionHouse/modify-unrecognized-param');
    emit ModifyParameters(parameter, data);
  }

  /**
   * @notice Modify an address parameter
   * @param parameter The name of the oracle contract modified
   * @param addr New contract address
   */
  function modifyParameters(bytes32 parameter, address addr) external isAuthorized {
    require(contractEnabled == 1, 'DebtAuctionHouse/contract-not-enabled');
    if (parameter == 'protocolToken') protocolToken = TokenLike(addr);
    else if (parameter == 'accountingEngine') accountingEngine = addr;
    else revert('DebtAuctionHouse/modify-unrecognized-param');
    emit ModifyParameters(parameter, addr);
  }

  // --- Auction ---
  /**
   * @notice Start a new debt auction
   * @param incomeReceiver Who receives the auction proceeds
   * @param amountToSell Amount of protocol tokens to sell (wad)
   * @param initialBid Initial bid size (rad)
   */
  function startAuction(
    address incomeReceiver,
    uint256 amountToSell,
    uint256 initialBid
  ) external isAuthorized returns (uint256 id) {
    require(contractEnabled == 1, 'DebtAuctionHouse/contract-not-enabled');
    require(auctionsStarted < type(uint256).max, 'DebtAuctionHouse/overflow');
    id = ++auctionsStarted;

    bids[id].bidAmount = initialBid;
    bids[id].amountToSell = amountToSell;
    bids[id].highBidder = incomeReceiver;
    bids[id].auctionDeadline = uint48(block.timestamp) + totalAuctionLength;

    ++activeDebtAuctions;

    emit StartAuction(
      id, auctionsStarted, amountToSell, initialBid, incomeReceiver, bids[id].auctionDeadline, activeDebtAuctions
    );
  }

  /**
   * @notice Restart an auction if no bids were submitted for it
   * @param id ID of the auction to restart
   */
  function restartAuction(uint256 id) external {
    require(id <= auctionsStarted, 'DebtAuctionHouse/auction-never-started');
    require(bids[id].auctionDeadline < block.timestamp, 'DebtAuctionHouse/not-finished');
    require(bids[id].bidExpiry == 0, 'DebtAuctionHouse/bid-already-placed');
    bids[id].amountToSell = (amountSoldIncrease * bids[id].amountToSell) / WAD;
    bids[id].auctionDeadline = uint48(block.timestamp) + totalAuctionLength;
    emit RestartAuction(id, bids[id].auctionDeadline);
  }

  /**
   * @notice Decrease the protocol token amount you're willing to receive in
   *         exchange for providing the same amount of system coins being raised by the auction
   * @param id ID of the auction for which you want to submit a new bid
   * @param amountToBuy Amount of protocol tokens to buy (must be smaller than the previous proposed amount) (wad)
   * @param bid New system coin bid (must always equal the total amount raised by the auction) (rad)
   */
  function decreaseSoldAmount(uint256 id, uint256 amountToBuy, uint256 bid) external {
    require(contractEnabled == 1, 'DebtAuctionHouse/contract-not-enabled');
    require(bids[id].highBidder != address(0), 'DebtAuctionHouse/high-bidder-not-set');
    require(bids[id].bidExpiry > block.timestamp || bids[id].bidExpiry == 0, 'DebtAuctionHouse/bid-already-expired');
    require(bids[id].auctionDeadline > block.timestamp, 'DebtAuctionHouse/auction-already-expired');

    require(bid == bids[id].bidAmount, 'DebtAuctionHouse/not-matching-bid');
    require(amountToBuy < bids[id].amountToSell, 'DebtAuctionHouse/amount-bought-not-lower');
    require(bidDecrease * amountToBuy <= bids[id].amountToSell * WAD, 'DebtAuctionHouse/insufficient-decrease');

    safeEngine.transferInternalCoins(msg.sender, bids[id].highBidder, bid);

    // on first bid submitted, clear as much totalOnAuctionDebt as possible
    if (bids[id].bidExpiry == 0) {
      uint256 totalOnAuctionDebt = AccountingEngineLike(bids[id].highBidder).totalOnAuctionDebt();
      AccountingEngineLike(bids[id].highBidder).cancelAuctionedDebtWithSurplus(Math.min(bid, totalOnAuctionDebt));
    }

    bids[id].highBidder = msg.sender;
    bids[id].amountToSell = amountToBuy;
    bids[id].bidExpiry = uint48(block.timestamp) + bidDuration;

    emit DecreaseSoldAmount(id, msg.sender, amountToBuy, bid, bids[id].bidExpiry);
  }

  /**
   * @notice Settle/finish an auction
   * @param id ID of the auction to settle
   */
  function settleAuction(uint256 id) external {
    require(contractEnabled == 1, 'DebtAuctionHouse/not-live');
    require(
      bids[id].bidExpiry != 0 && (bids[id].bidExpiry < block.timestamp || bids[id].auctionDeadline < block.timestamp),
      'DebtAuctionHouse/not-finished'
    );
    protocolToken.mint(bids[id].highBidder, bids[id].amountToSell);
    --activeDebtAuctions;
    delete bids[id];
    emit SettleAuction(id, activeDebtAuctions);
  }

  // --- Shutdown ---
  /**
   * @notice Disable the auction house (usually called by the AccountingEngine)
   */
  function disableContract() external isAuthorized {
    contractEnabled = 0;
    accountingEngine = msg.sender;
    activeDebtAuctions = 0;
    emit DisableContract(msg.sender);
  }

  /**
   * @notice Terminate an auction prematurely
   * @param id ID of the auction to terminate
   */
  function terminateAuctionPrematurely(uint256 id) external {
    require(contractEnabled == 0, 'DebtAuctionHouse/contract-still-enabled');
    require(bids[id].highBidder != address(0), 'DebtAuctionHouse/high-bidder-not-set');
    safeEngine.createUnbackedDebt(accountingEngine, bids[id].highBidder, bids[id].bidAmount);
    emit TerminateAuctionPrematurely(id, msg.sender, bids[id].highBidder, bids[id].bidAmount, activeDebtAuctions);
    delete bids[id];
  }
}