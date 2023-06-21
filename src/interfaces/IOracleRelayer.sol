// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

import {IBaseOracle} from '@interfaces/oracles/IBaseOracle.sol';
import {IAuthorizable} from '@interfaces/utils/IAuthorizable.sol';
import {IModifiable} from '@interfaces/utils/IModifiable.sol';
import {ISAFEEngine} from '@interfaces/ISAFEEngine.sol';
import {IDisableable} from '@interfaces/utils/IDisableable.sol';

interface IOracleRelayer is IAuthorizable, IModifiable, IDisableable {
  // --- Events ---
  event UpdateRedemptionPrice(uint256 _redemptionPrice);
  event UpdateCollateralPrice(
    bytes32 indexed _collateralType, uint256 _priceFeedValue, uint256 _safetyPrice, uint256 _liquidationPrice
  );

  // --- Errors ---
  error RedemptionPriceNotUpdated();
  error OracleRelayer_CollateralTypeAlreadyInitialized();

  // --- Structs ---
  struct OracleRelayerParams {
    // Upper bound for the per-second redemption rate
    uint256 redemptionRateUpperBound; // [ray]
    // Lower bound for the per-second redemption rate
    uint256 redemptionRateLowerBound; // [ray]
  }

  struct OracleRelayerCollateralParams {
    // Usually an oracle security module that enforces delays to fresh price feeds
    IBaseOracle oracle;
    // CRatio used to compute the 'safePrice' - the price used when generating debt in SAFEEngine
    uint256 safetyCRatio;
    // CRatio used to compute the 'liquidationPrice' - the price used when liquidating SAFEs
    uint256 liquidationCRatio;
  }

  // --- Registry ---
  function safeEngine() external view returns (ISAFEEngine _safeEngine);

  /**
   * @notice The oracle used to fetch the system coin market price
   */
  function systemCoinOracle() external view returns (IBaseOracle _systemCoinOracle);

  // --- Params ---
  function params() external view returns (OracleRelayerParams memory _params);
  function cParams(bytes32) external view returns (OracleRelayerCollateralParams memory _cParams);

  // --- Data ---
  function marketPrice() external view returns (uint256 _marketPrice);
  function redemptionRate() external view returns (uint256 _redemptionRate);
  function redemptionPriceUpdateTime() external view returns (uint256 _redemptionPriceUpdateTime);

  // --- Methods ---
  function redemptionPrice() external returns (uint256 _redemptionPrice);
  function updateCollateralPrice(bytes32 _collateralType) external;
  function updateRedemptionRate(uint256 _redemptionRate) external;
  function initializeCollateralType(bytes32 _cType, OracleRelayerCollateralParams memory _collateralParams) external;
}
