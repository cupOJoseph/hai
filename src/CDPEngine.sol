/// CDPEngine.sol -- CDP database

// Copyright (C) 2018 Rain <rainbreak@riseup.net>
// Copyright (C) 2020 Stefan C. Ionescu <stefanionescu@protonmail.com>
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

pragma solidity ^0.5.15;

contract CDPEngine {
    // --- Auth ---
    mapping (address => uint) public authorizedAccounts;
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) external emitLog isAuthorized {
      require(contractEnabled == 1, "CDPEngine/contract-not-enabled"); authorizedAccounts[account] = 1;
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) external emitLog isAuthorized {
      require(contractEnabled == 1, "CDPEngine/contract-not-enabled"); authorizedAccounts[account] = 0;
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "CDPEngine/account-not-authorized");
        _;
    }

    // Who can transfer collateral & debt in/out of a CDP
    mapping(address => mapping (address => uint)) public cdpRights;
    /**
     * @notice Allow an address to modify your CDP
     * @param account Account to give CDP permissions to
     */
    function approveCDPModification(address account) external emitLog { cdpRights[msg.sender][account] = 1; }
    /**
     * @notice Deny an address the rights to modify your CDP
     * @param account Account to give CDP permissions to
     */
    function denyCDPModification(address account) external emitLog { cdpRights[msg.sender][account] = 0; }
    /**
    * @notice Checks whether msg.sender has the right to modify a CDP
    **/
    function canModifyCDP(address cdp, address account) public view returns (bool) {
        return either(cdp == account, cdpRights[cdp][account] == 1);
    }

    // --- Data ---
    struct CollateralType {
        // Total debt issued for this specific collateral type
        uint256 debtAmount;        // wad
        // Accumulator for interest accrued on this collateral type
        uint256 accumulatedRates;  // ray
        // Floor price at which a CDP is allowed to generate debt
        uint256 safetyPrice;       // ray
        // Maximum amount of debt that can be generated with this collateral type
        uint256 debtCeiling;       // rad
        // Minimum amount of debt that must be generated by a CDP using this collateral
        uint256 debtFloor;         // rad
        // Price at which a CDP gets liquidated
        uint256 liquidationPrice;  // ray
    }
    struct CDP {
        // Total amount of collateral locked in a CDP
        uint256 lockedCollateral;  // wad
        // Total amount of debt generated by a CDP
        uint256 generatedDebt;     // wad
    }

    // Data about each collateral type
    mapping (bytes32 => CollateralType)            public collateralTypes;
    // Data about each CDP
    mapping (bytes32 => mapping (address => CDP )) public cdps;
    // Balance of each collateral type
    mapping (bytes32 => mapping (address => uint)) public tokenCollateral;  // [wad]
    // Internal balance of reflex-bonds/pegged-coins
    mapping (address => uint)                      public coinBalance;      // [rad]
    // Amount of debt held by an account. Coin & debt are like matter and antimatter. They nullify each other
    mapping (address => uint)                      public debtBalance;      // [rad]

    // Total amount of debt (coins) currently issued
    uint256  public globalDebt;          // rad
    // 'Bad' debt that's not covered by collateral
    uint256  public globalUnbackedDebt;  // rad
    // Maximum amount of debt that can be issued
    uint256  public globalDebtCeiling;   // rad
    // Access flag, indicates whether this contract is still active
    uint256  public contractEnabled;

    // --- Logs ---
    event LogNote(
        bytes4   indexed  sig,
        bytes32  indexed  arg1,
        bytes32  indexed  arg2,
        bytes32  indexed  arg3,
        bytes             data
    ) anonymous;

    /**
    * @notice Log an 'anonymous' event with a constant 6 words of calldata
    * and four indexed topics: the selector and the first three args
    **/
    modifier emitLog {
        _;
        assembly {
            //
            //
            let mark := msize                         // end of memory ensures zero
            mstore(0x40, add(mark, 288))              // update free memory pointer
            mstore(mark, 0x20)                        // bytes type data offset
            mstore(add(mark, 0x20), 224)              // bytes size (padded)
            calldatacopy(add(mark, 0x40), 0, 224)     // bytes payload
            log4(mark, 288,                           // calldata
                 shl(224, shr(224, calldataload(0))), // msg.sig
                 calldataload(4),                     // arg1
                 calldataload(36),                    // arg2
                 calldataload(68)                     // arg3
                )
        }
    }

    // --- Init ---
    constructor() public {
        authorizedAccounts[msg.sender] = 1;
        contractEnabled = 1;
    }

    // --- Math ---
    function add(uint x, int y) internal pure returns (uint z) {
        z = x + uint(y);
        require(y >= 0 || z <= x);
        require(y <= 0 || z >= x);
    }
    function add(int x, int y) internal pure returns (int z) {
        z = x + y;
        require(y >= 0 || z <= x);
        require(y <= 0 || z >= x);
    }
    function sub(uint x, int y) internal pure returns (uint z) {
        z = x - uint(y);
        require(y <= 0 || z <= x);
        require(y >= 0 || z >= x);
    }
    function sub(int x, int y) internal pure returns (int z) {
        z = x - y;
        require(y <= 0 || z <= x);
        require(y >= 0 || z >= x);
    }
    function mul(uint x, int y) internal pure returns (int z) {
        z = int(x) * y;
        require(int(x) >= 0);
        require(y == 0 || z / y == int(x));
    }
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }
    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }
    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    // --- Administration ---

    /**
     * @notice Creates a brand new collateral type
     * @param collateralType Collateral type name (e.g ETH-A, TBTC-B)
     */
    function initializeCollateralType(bytes32 collateralType) external emitLog isAuthorized {
        require(collateralTypes[collateralType].accumulatedRates == 0, "CDPEngine/collateral-type-already-exists");
        collateralTypes[collateralType].accumulatedRates = 10 ** 27;
    }
    /**
     * @notice Modify general uint params
     * @param parameter The name of the parameter modified
     * @param data New value for the parameter
     */
    function modifyParameters(bytes32 parameter, uint data) external emitLog isAuthorized {
        require(contractEnabled == 1, "CDPEngine/contract-not-enabled");
        if (parameter == "globalDebtCeiling") globalDebtCeiling = data;
        else revert("CDPEngine/modify-unrecognized-param");
    }
    /**
     * @notice Modify collateral specific params
     * @param collateralType Collateral type we modify params for
     * @param parameter The name of the parameter modified
     * @param data New value for the parameter
     */
    function modifyParameters(
        bytes32 collateralType,
        bytes32 parameter,
        uint data
    ) external emitLog isAuthorized {
        require(contractEnabled == 1, "CDPEngine/contract-not-enabled");
        if (parameter == "safetyPrice") collateralTypes[collateralType].safetyPrice = data;
        else if (parameter == "liquidationPrice") collateralTypes[collateralType].liquidationPrice = data;
        else if (parameter == "debtCeiling") collateralTypes[collateralType].debtCeiling = data;
        else if (parameter == "debtFloor") collateralTypes[collateralType].debtFloor = data;
        else revert("CDPEngine/modify-unrecognized-param");
    }
    /**
     * @notice Disable this contract (normally called by GlobalSettlement)
     */
    function disableContract() external emitLog isAuthorized {
        contractEnabled = 0;
    }

    // --- Fungibility ---
    /**
     * @notice Join/exit collateral into and and out of the system
     * @param collateralType Collateral type we join/exit
     * @param account Account that gets credited/debited
     * @param wad Amount of collateral (expressed as a number with 18 decimals)
     */
    function modifyCollateralBalance(
        bytes32 collateralType,
        address account,
        int256 wad
    ) external emitLog isAuthorized {
        tokenCollateral[collateralType][account] = add(tokenCollateral[collateralType][account], wad);
    }
    /**
     * @notice Transfer collateral between accounts
     * @param collateralType Collateral type transferred
     * @param src Collateral source
     * @param dst Collateral destination
     * @param wad Amount of collateral transferred (expressed as a number with 18 decimals)
     */
    function transferCollateral(
        bytes32 collateralType,
        address src,
        address dst,
        uint256 wad
    ) external emitLog {
        require(canModifyCDP(src, msg.sender), "CDPEngine/not-allowed");
        tokenCollateral[collateralType][src] = sub(tokenCollateral[collateralType][src], wad);
        tokenCollateral[collateralType][dst] = add(tokenCollateral[collateralType][dst], wad);
    }
    /**
     * @notice Transfer internal coins (does not affect external balances from Coin.sol)
     * @param src Coins source
     * @param dst Coins destination
     * @param rad Amount of coins transferred (expressed as a number with 45 decimals)
     */
    function transferInternalCoins(address src, address dst, uint256 rad) external emitLog {
        require(canModifyCDP(src, msg.sender), "CDPEngine/not-allowed");
        coinBalance[src] = sub(coinBalance[src], rad);
        coinBalance[dst] = add(coinBalance[dst], rad);
    }

    function either(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    // --- CDP Manipulation ---
    /**
     * @notice Add/remove collateral or put back/generate more debt in a CDP
     * @param collateralType Type of collateral to withdraw/deposit in and from the CDP
     * @param cdp Target CDP
     * @param collateralSource Account we take collateral from/put collateral into
     * @param debtDestination Account from which we credit/debit coins and debt
     * @param deltaCollateral Amount of collateral added/extract from the CDP
     * @param deltaDebt Amount of debt to generate/repay
     */
    function modifyCDPCollateralization(
        bytes32 collateralType,
        address cdp,
        address collateralSource,
        address debtDestination,
        int deltaCollateral,
        int deltaDebt
    ) external emitLog {
        // system is live
        require(contractEnabled == 1, "CDPEngine/contract-not-enabled");

        CDP memory cdp_ = cdps[collateralType][cdp];
        CollateralType memory collateralType_ = collateralTypes[collateralType];
        // ilk has been initialised
        require(collateralType_.accumulatedRates != 0, "CDPEngine/collateral-type-not-initialized");

        cdp_.lockedCollateral      = add(cdp_.lockedCollateral, deltaCollateral);
        cdp_.generatedDebt         = add(cdp_.generatedDebt, deltaDebt);
        collateralType_.debtAmount = add(collateralType_.debtAmount, deltaDebt);

        int deltaAdjustedDebt = mul(collateralType_.accumulatedRates, deltaDebt);
        uint totalDebtIssued  = mul(collateralType_.accumulatedRates, cdp_.generatedDebt);
        globalDebt            = add(globalDebt, deltaAdjustedDebt);

        // either debt has decreased, or debt ceilings are not exceeded
        require(
          either(
            deltaDebt <= 0,
            both(mul(collateralType_.debtAmount, collateralType_.accumulatedRates) <= collateralType_.debtCeiling,
              globalDebt <= globalDebtCeiling)
            ),
          "CDPEngine/ceiling-exceeded"
        );
        // cdp is either less risky than before, or it is safe
        require(
          either(
            both(deltaDebt <= 0, deltaCollateral >= 0),
            totalDebtIssued <= mul(cdp_.lockedCollateral, collateralType_.safetyPrice)
          ),
          "CDPEngine/not-safe"
        );

        // cdp is either more safe, or the owner consents
        require(either(both(deltaDebt <= 0, deltaCollateral >= 0), canModifyCDP(cdp, msg.sender)), "CDPEngine/not-allowed-to-modify-cdp");
        // collateral src consents
        require(either(deltaCollateral <= 0, canModifyCDP(collateralSource, msg.sender)), "CDPEngine/not-allowed-collateral-src");
        // debt dst consents
        require(either(deltaDebt >= 0, canModifyCDP(debtDestination, msg.sender)), "CDPEngine/not-allowed-debt-dst");

        // cdp has no debt, or a non-dusty amount
        require(either(cdp_.generatedDebt == 0, totalDebtIssued >= collateralType_.debtFloor), "CDPEngine/dust");

        tokenCollateral[collateralType][collateralSource] =
          sub(tokenCollateral[collateralType][collateralSource], deltaCollateral);

        coinBalance[debtDestination] = add(coinBalance[debtDestination], deltaAdjustedDebt);

        cdps[collateralType][cdp] = cdp_;
        collateralTypes[collateralType] = collateralType_;
    }

    // --- CDP Insurance ---
    /**
     * @notice Add more collateral in a CDP and reward the keeper who initially wanted to liquidate the CDP
     * @param collateralType Type of collateral to add to the CDP and reward the keeper with
     * @param cdp Target CDP
     * @param liquidator Actor who called LiquidationEngine.liquidateCDP and then the CDPSaviour
       triggered this function
     * @param collateralToAdd Amount of collateral to add in the CDP
     * @param reward Amount of collateralType to give to the keeper
     */
    function saveCDP(
        bytes32 collateralType,
        address cdp,
        address liquidator,
        uint collateralToAdd,
        uint reward
    ) external emitLog isAuthorized {
        require(contractEnabled == 1, "CDPEngine/contract-not-enabled");
        require(liquidator != address(0), "CDPEngine/null-liquidator");
        require(collateralTypes[collateralType].accumulatedRates > 0, "CDPEngine/inexistent-collateral-type");
        cdps[collateralType][cdp].lockedCollateral =
          add(cdps[collateralType][cdp].lockedCollateral, collateralToAdd);
        tokenCollateral[collateralType][liquidator] =
          add(tokenCollateral[collateralType][liquidator], reward);
    }

    // --- CDP Fungibility ---
    /**
     * @notice Transfer collateral and/or debt between CDPs
     * @param collateralType Collateral type transferred between CDPs
     * @param src Source CDP
     * @param dst Destination CDP
     * @param deltaCollateral Amount of collateral to take/add into src and give/take from dst
     * @param deltaDebt Amount of debt to take/add into src and give/take from dst
     */
    function transferCDPCollateralAndDebt(
        bytes32 collateralType,
        address src,
        address dst,
        int deltaCollateral,
        int deltaDebt
    ) external emitLog {
        CDP storage srcCDP = cdps[collateralType][src];
        CDP storage dstCDP = cdps[collateralType][dst];
        CollateralType storage collateralType_ = collateralTypes[collateralType];

        srcCDP.lockedCollateral = sub(srcCDP.lockedCollateral, deltaCollateral);
        srcCDP.generatedDebt    = sub(srcCDP.generatedDebt, deltaDebt);
        dstCDP.lockedCollateral = add(dstCDP.lockedCollateral, deltaCollateral);
        dstCDP.generatedDebt    = add(dstCDP.generatedDebt, deltaDebt);

        uint srcTotalDebtIssued = mul(srcCDP.generatedDebt, collateralType_.accumulatedRates);
        uint dstTotalDebtIssued = mul(dstCDP.generatedDebt, collateralType_.accumulatedRates);

        // both sides consent
        require(both(canModifyCDP(src, msg.sender), canModifyCDP(dst, msg.sender)), "CDPEngine/not-allowed");

        // both sides safe
        require(srcTotalDebtIssued <= mul(srcCDP.lockedCollateral, collateralType_.safetyPrice), "CDPEngine/not-safe-src");
        require(dstTotalDebtIssued <= mul(dstCDP.lockedCollateral, collateralType_.safetyPrice), "CDPEngine/not-safe-dst");

        // both sides non-dusty
        require(either(srcTotalDebtIssued >= collateralType_.debtFloor, srcCDP.generatedDebt == 0), "CDPEngine/dust-src");
        require(either(dstTotalDebtIssued >= collateralType_.debtFloor, dstCDP.generatedDebt == 0), "CDPEngine/dust-dst");
    }

    // --- CDP Confiscation ---
    /**
     * @notice Normally used by the LiquidationEngine in order to confiscate collateral and
       debt from a CDP and give them to someone else
     * @param collateralType Collateral type the CDP has locked inside
     * @param cdp Target CDP
     * @param collateralCounterparty Who we take/give collateral to
     * @param debtCounterparty Who we take/give debt to
     * @param deltaCollateral Amount of collateral taken/added into the CDP
     * @param deltaDebt Amount of collateral taken/added into the CDP
     */
    function confiscateCDPCollateralAndDebt(
        bytes32 collateralType,
        address cdp,
        address collateralCounterparty,
        address debtCounterparty,
        int deltaCollateral,
        int deltaDebt
    ) external emitLog isAuthorized {
        CDP storage cdp_ = cdps[collateralType][cdp];
        CollateralType storage collateralType_ = collateralTypes[collateralType];

        cdp_.lockedCollateral = add(cdp_.lockedCollateral, deltaCollateral);
        cdp_.generatedDebt = add(cdp_.generatedDebt, deltaDebt);
        collateralType_.debtAmount = add(collateralType_.debtAmount, deltaDebt);

        int deltaTotalIssuedDebt = mul(collateralType_.accumulatedRates, deltaDebt);

        tokenCollateral[collateralType][collateralCounterparty] = sub(
          tokenCollateral[collateralType][collateralCounterparty],
          deltaCollateral
        );
        debtBalance[debtCounterparty] = sub(
          debtBalance[debtCounterparty],
          deltaTotalIssuedDebt
        );
        globalUnbackedDebt = sub(
          globalUnbackedDebt,
          deltaTotalIssuedDebt
        );
    }

    // --- Settlement ---
    /**
     * @notice Nullify an amount of coins with an equal amount of debt
     * @param rad Amount of debt & coins to destroy (expressed as a number with 45 decimals)
     */
    function settleDebt(uint rad) external emitLog {
        address account       = msg.sender;
        debtBalance[account]  = sub(debtBalance[account], rad);
        coinBalance[account]  = sub(coinBalance[account], rad);
        globalUnbackedDebt    = sub(globalUnbackedDebt, rad);
        globalDebt            = sub(globalDebt, rad);
    }
    /**
     * @notice Usually called by CoinSavingsAccount in order to create unbacked debt
     * @param debtDestination Usually AccountingEngine that can settle dent with surplus
     * @param coinDestination Usually CoinSavingsAccount who passes the new coins to depositors
     * @param rad Amount of debt to create (expressed as a number with 45 decimals)
     */
    function createUnbackedDebt(
        address debtDestination,
        address coinDestination,
        uint rad
    ) external emitLog isAuthorized {
        debtBalance[debtDestination]  = add(debtBalance[debtDestination], rad);
        coinBalance[coinDestination]  = add(coinBalance[coinDestination], rad);
        globalUnbackedDebt            = add(globalUnbackedDebt, rad);
        globalDebt                    = add(globalDebt, rad);
    }

    // --- Rates ---
    /**
     * @notice Usually called by TaxCollector in order to accrue interest on a specific collateral type
     * @param collateralType Collateral type we accrue interest for
     * @param surplusDst Destination for amount of surplus created by applying the interest rate
       to debt created by CDPs with 'collateralType'
     * @param rateMultiplier Multiplier applied to the debtAmount in order to calculate the surplus
     */
    function updateAccumulatedRate(
        bytes32 collateralType,
        address surplusDst,
        int rateMultiplier
    ) external emitLog isAuthorized {
        require(contractEnabled == 1, "CDPEngine/contract-not-enabled");
        CollateralType storage collateralType_ = collateralTypes[collateralType];
        collateralType_.accumulatedRates       = add(collateralType_.accumulatedRates, rateMultiplier);
        int deltaSurplus                       = mul(collateralType_.debtAmount, rateMultiplier);
        coinBalance[surplusDst]                = add(coinBalance[surplusDst], deltaSurplus);
        globalDebt                             = add(globalDebt, deltaSurplus);
    }
}
