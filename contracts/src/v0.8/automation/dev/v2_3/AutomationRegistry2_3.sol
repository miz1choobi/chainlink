// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {EnumerableSet} from "../../../vendor/openzeppelin-solidity/v4.7.3/contracts/utils/structs/EnumerableSet.sol";
import {Address} from "../../../vendor/openzeppelin-solidity/v4.7.3/contracts/utils/Address.sol";
import {AutomationRegistryBase2_3} from "./AutomationRegistryBase2_3.sol";
import {AutomationRegistryLogicB2_3} from "./AutomationRegistryLogicB2_3.sol";
import {Chainable} from "../../Chainable.sol";
import {IERC677Receiver} from "../../../shared/interfaces/IERC677Receiver.sol";
import {OCR2Abstract} from "../../../shared/ocr2/OCR2Abstract.sol";
import {IERC20} from "../../../vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Registry for adding work for Chainlink nodes to perform on client
 * contracts. Clients must support the AutomationCompatibleInterface interface.
 */
contract AutomationRegistry2_3 is AutomationRegistryBase2_3, OCR2Abstract, Chainable, IERC677Receiver {
  using Address for address;
  using EnumerableSet for EnumerableSet.UintSet;
  using EnumerableSet for EnumerableSet.AddressSet;

  /**
   * @notice versions:
   * AutomationRegistry 2.3.0: supports native and ERC20 billing
   * AutomationRegistry 2.2.0: moves chain-specific integration code into a separate module
   * KeeperRegistry 2.1.0:     introduces support for log triggers
   *                           removes the need for "wrapped perform data"
   * KeeperRegistry 2.0.2:     pass revert bytes as performData when target contract reverts
   *                           fixes issue with arbitrum block number
   *                           does an early return in case of stale report instead of revert
   * KeeperRegistry 2.0.1:     implements workaround for buggy migrate function in 1.X
   * KeeperRegistry 2.0.0:     implement OCR interface
   * KeeperRegistry 1.3.0:     split contract into Proxy and Logic
   *                           account for Arbitrum and Optimism L1 gas fee
   *                           allow users to configure upkeeps
   * KeeperRegistry 1.2.0:     allow funding within performUpkeep
   *                           allow configurable registry maxPerformGas
   *                           add function to let admin change upkeep gas limit
   *                           add minUpkeepSpend requirement
   *                           upgrade to solidity v0.8
   * KeeperRegistry 1.1.0:     added flatFeeMicroLink
   * KeeperRegistry 1.0.0:     initial release
   */
  string public constant override typeAndVersion = "AutomationRegistry 2.3.0";

  /**
   * @param logicA the address of the first logic contract, but cast as logicB in order to call logicB functions (via fallback)
   */
  constructor(
    AutomationRegistryLogicB2_3 logicA
  )
    AutomationRegistryBase2_3(
      logicA.getLinkAddress(),
      logicA.getLinkUSDFeedAddress(),
      logicA.getNativeUSDFeedAddress(),
      logicA.getFastGasFeedAddress(),
      logicA.getAutomationForwarderLogic(),
      logicA.getAllowedReadOnlyAddress()
    )
    Chainable(address(logicA))
  {}

  /**
   * @notice holds the variables used in the transmit function, necessary to avoid stack too deep errors
   */
  struct TransmitVars {
    uint16 numUpkeepsPassedChecks;
    uint96 totalReimbursement;
    uint96 totalPremium;
    uint256 totalCalldataWeight;
  }

  // ================================================================
  // |                           ACTIONS                            |
  // ================================================================

  /**
   * @inheritdoc OCR2Abstract
   */
  function transmit(
    bytes32[3] calldata reportContext,
    bytes calldata rawReport,
    bytes32[] calldata rs,
    bytes32[] calldata ss,
    bytes32 rawVs
  ) external override {
    uint256 gasOverhead = gasleft();
    HotVars memory hotVars = s_hotVars;

    if (hotVars.paused) revert RegistryPaused();
    if (!s_transmitters[msg.sender].active) revert OnlyActiveTransmitters();

    // Verify signatures
    if (s_latestConfigDigest != reportContext[0]) revert ConfigDigestMismatch();
    if (rs.length != hotVars.f + 1 || rs.length != ss.length) revert IncorrectNumberOfSignatures();
    _verifyReportSignature(reportContext, rawReport, rs, ss, rawVs);

    Report memory report = _decodeReport(rawReport);

    uint40 epochAndRound = uint40(uint256(reportContext[1]));
    uint32 epoch = uint32(epochAndRound >> 8);

    _handleReport(hotVars, report, gasOverhead);

    if (epoch > hotVars.latestEpoch) {
      s_hotVars.latestEpoch = epoch;
    }
  }

  function _handleReport(HotVars memory hotVars, Report memory report, uint256 gasOverhead) private {
    UpkeepTransmitInfo[] memory upkeepTransmitInfo = new UpkeepTransmitInfo[](report.upkeepIds.length);
    TransmitVars memory transmitVars = TransmitVars({
      numUpkeepsPassedChecks: 0,
      totalCalldataWeight: 0,
      totalReimbursement: 0,
      totalPremium: 0
    });

    uint256 blocknumber = hotVars.chainModule.blockNumber();
    uint256 l1Fee = hotVars.chainModule.getCurrentL1Fee();

    for (uint256 i = 0; i < report.upkeepIds.length; i++) {
      upkeepTransmitInfo[i].upkeep = s_upkeep[report.upkeepIds[i]];
      upkeepTransmitInfo[i].triggerType = _getTriggerType(report.upkeepIds[i]);

      (upkeepTransmitInfo[i].earlyChecksPassed, upkeepTransmitInfo[i].dedupID) = _prePerformChecks(
        report.upkeepIds[i],
        blocknumber,
        report.triggers[i],
        upkeepTransmitInfo[i],
        hotVars
      );

      if (upkeepTransmitInfo[i].earlyChecksPassed) {
        transmitVars.numUpkeepsPassedChecks += 1;
      } else {
        continue;
      }

      // Actually perform the target upkeep
      (upkeepTransmitInfo[i].performSuccess, upkeepTransmitInfo[i].gasUsed) = _performUpkeep(
        upkeepTransmitInfo[i].upkeep.forwarder,
        report.gasLimits[i],
        report.performDatas[i]
      );

      // To split L1 fee across the upkeeps, assign a weight to this upkeep based on the length
      // of the perform data and calldata overhead
      upkeepTransmitInfo[i].calldataWeight =
        report.performDatas[i].length +
        TRANSMIT_CALLDATA_FIXED_BYTES_OVERHEAD +
        (TRANSMIT_CALLDATA_PER_SIGNER_BYTES_OVERHEAD * (hotVars.f + 1));
      transmitVars.totalCalldataWeight += upkeepTransmitInfo[i].calldataWeight;

      // Deduct that gasUsed by upkeep from our running counter
      gasOverhead -= upkeepTransmitInfo[i].gasUsed;

      // Store last perform block number / deduping key for upkeep
      _updateTriggerMarker(report.upkeepIds[i], blocknumber, upkeepTransmitInfo[i]);
    }
    // No upkeeps to be performed in this report
    if (transmitVars.numUpkeepsPassedChecks == 0) {
      return;
    }

    // This is the overall gas overhead that will be split across performed upkeeps
    // Take upper bound of 16 gas per callData bytes
    gasOverhead = (gasOverhead - gasleft()) + (16 * msg.data.length) + ACCOUNTING_FIXED_GAS_OVERHEAD;
    gasOverhead = gasOverhead / transmitVars.numUpkeepsPassedChecks + ACCOUNTING_PER_UPKEEP_GAS_OVERHEAD;

    {
      BillingTokenPaymentParams memory billingTokenParams;
      for (uint256 i = 0; i < report.upkeepIds.length; i++) {
        if (upkeepTransmitInfo[i].earlyChecksPassed) {
          billingTokenParams = _getBillingTokenPaymentParams(hotVars, upkeepTransmitInfo[i].upkeep.billingToken); // TODO avoid doing this every time
          PaymentReceipt memory receipt = _handlePayment(
            hotVars,
            PaymentParams({
              gasLimit: upkeepTransmitInfo[i].gasUsed,
              gasOverhead: gasOverhead,
              l1CostWei: (l1Fee * upkeepTransmitInfo[i].calldataWeight) / transmitVars.totalCalldataWeight,
              fastGasWei: report.fastGasWei,
              linkUSD: report.linkUSD,
              nativeUSD: _getNativeUSD(hotVars),
              billingToken: billingTokenParams,
              isTransaction: true
            }),
            report.upkeepIds[i]
          );
          transmitVars.totalPremium += receipt.premiumJuels;
          transmitVars.totalReimbursement += receipt.gasReimbursementJuels;

          emit UpkeepPerformed(
            report.upkeepIds[i],
            upkeepTransmitInfo[i].performSuccess,
            // receipt.gasCharge + receipt.premium, // TODO - this is currently the billing token amount, but should it be?
            receipt.gasReimbursementJuels + receipt.premiumJuels, // TODO - this is currently the link tokn amount, but should it be billing token instead?
            upkeepTransmitInfo[i].gasUsed,
            gasOverhead,
            report.triggers[i]
          );
        }
      }
    }
    // record payments
    s_transmitters[msg.sender].balance += transmitVars.totalReimbursement;
    s_hotVars.totalPremium += transmitVars.totalPremium;
  }

  /**
   * @notice simulates the upkeep with the perform data returned from checkUpkeep
   * @param id identifier of the upkeep to execute the data with.
   * @param performData calldata parameter to be passed to the target upkeep.
   * @return success whether the call reverted or not
   * @return gasUsed the amount of gas the target contract consumed
   */
  function simulatePerformUpkeep(
    uint256 id,
    bytes calldata performData
  ) external returns (bool success, uint256 gasUsed) {
    _preventExecution();

    if (s_hotVars.paused) revert RegistryPaused();
    Upkeep memory upkeep = s_upkeep[id];
    (success, gasUsed) = _performUpkeep(upkeep.forwarder, upkeep.performGas, performData);
    return (success, gasUsed);
  }

  /**
   * @notice uses LINK's transferAndCall to LINK and add funding to an upkeep
   * @dev safe to cast uint256 to uint96 as total LINK supply is under UINT96MAX
   * @param sender the account which transferred the funds
   * @param amount number of LINK transfer
   */
  function onTokenTransfer(address sender, uint256 amount, bytes calldata data) external override {
    // TODO test that this reverts if the billing token != the link token
    if (msg.sender != address(i_link)) revert OnlyCallableByLINKToken();
    if (data.length != 32) revert InvalidDataLength();
    uint256 id = abi.decode(data, (uint256));
    if (s_upkeep[id].maxValidBlocknumber != UINT32_MAX) revert UpkeepCancelled();
    if (address(s_upkeep[id].billingToken) != address(i_link)) revert InvalidBillingToken();
    s_upkeep[id].balance = s_upkeep[id].balance + uint96(amount);
    s_reserveAmounts[address(i_link)] = s_reserveAmounts[address(i_link)] + amount;
    emit FundsAdded(id, sender, uint96(amount));
  }

  // ================================================================
  // |                           SETTERS                            |
  // ================================================================

  /**
   * @inheritdoc OCR2Abstract
   * @dev prefer the type-safe version of setConfig (below) whenever possible. The OnchainConfig could differ between registry versions
   */
  function setConfig(
    address[] memory signers,
    address[] memory transmitters,
    uint8 f,
    bytes memory onchainConfigBytes,
    uint64 offchainConfigVersion,
    bytes memory offchainConfig
  ) external override {
    (OnchainConfig memory config, IERC20[] memory billingTokens, BillingConfig[] memory billingConfigs) = abi.decode(
      onchainConfigBytes,
      (OnchainConfig, IERC20[], BillingConfig[])
    );

    setConfigTypeSafe(
      signers,
      transmitters,
      f,
      config,
      offchainConfigVersion,
      offchainConfig,
      billingTokens,
      billingConfigs
    );
  }

  function setConfigTypeSafe(
    address[] memory signers,
    address[] memory transmitters,
    uint8 f,
    OnchainConfig memory onchainConfig,
    uint64 offchainConfigVersion,
    bytes memory offchainConfig,
    IERC20[] memory billingTokens,
    BillingConfig[] memory billingConfigs
  ) public onlyOwner {
    if (signers.length > MAX_NUM_ORACLES) revert TooManyOracles();
    if (f == 0) revert IncorrectNumberOfFaultyOracles();
    if (signers.length != transmitters.length || signers.length <= 3 * f) revert IncorrectNumberOfSigners();
    if (billingTokens.length != billingConfigs.length) revert ParameterLengthError();
    // set billing config for tokens
    _setBillingConfig(billingTokens, billingConfigs);

    // move all pooled payments out of the pool to each transmitter's balance
    for (uint256 i = 0; i < s_transmittersList.length; i++) {
      _updateTransmitterBalanceFromPool(
        s_transmittersList[i],
        s_hotVars.totalPremium,
        uint96(s_transmittersList.length)
      );
    }

    // remove any old signer/transmitter addresses
    address signerAddress;
    address transmitterAddress;
    for (uint256 i = 0; i < s_transmittersList.length; i++) {
      signerAddress = s_signersList[i];
      transmitterAddress = s_transmittersList[i];
      delete s_signers[signerAddress];
      // Do not delete the whole transmitter struct as it has balance information stored
      s_transmitters[transmitterAddress].active = false;
    }
    delete s_signersList;
    delete s_transmittersList;

    // add new signer/transmitter addresses
    {
      Transmitter memory transmitter;
      address temp;
      for (uint256 i = 0; i < signers.length; i++) {
        if (s_signers[signers[i]].active) revert RepeatedSigner();
        if (signers[i] == ZERO_ADDRESS) revert InvalidSigner();
        s_signers[signers[i]] = Signer({active: true, index: uint8(i)});

        temp = transmitters[i];
        if (temp == ZERO_ADDRESS) revert InvalidTransmitter();
        transmitter = s_transmitters[temp];
        if (transmitter.active) revert RepeatedTransmitter();
        transmitter.active = true;
        transmitter.index = uint8(i);
        // new transmitters start afresh from current totalPremium
        // some spare change of premium from previous pool will be forfeited
        transmitter.lastCollected = s_hotVars.totalPremium;
        s_transmitters[temp] = transmitter;
      }
    }
    s_signersList = signers;
    s_transmittersList = transmitters;

    s_hotVars = HotVars({
      f: f,
      stalenessSeconds: onchainConfig.stalenessSeconds,
      gasCeilingMultiplier: onchainConfig.gasCeilingMultiplier,
      paused: s_hotVars.paused,
      reentrancyGuard: s_hotVars.reentrancyGuard,
      totalPremium: s_hotVars.totalPremium,
      latestEpoch: 0, // DON restarts epoch
      reorgProtectionEnabled: onchainConfig.reorgProtectionEnabled,
      chainModule: onchainConfig.chainModule
    });

    s_storage = Storage({
      checkGasLimit: onchainConfig.checkGasLimit,
      maxPerformGas: onchainConfig.maxPerformGas,
      transcoder: onchainConfig.transcoder,
      maxCheckDataSize: onchainConfig.maxCheckDataSize,
      maxPerformDataSize: onchainConfig.maxPerformDataSize,
      maxRevertDataSize: onchainConfig.maxRevertDataSize,
      upkeepPrivilegeManager: onchainConfig.upkeepPrivilegeManager,
      financeAdmin: onchainConfig.financeAdmin,
      nonce: s_storage.nonce,
      configCount: s_storage.configCount,
      latestConfigBlockNumber: s_storage.latestConfigBlockNumber
    });
    s_fallbackGasPrice = onchainConfig.fallbackGasPrice;
    s_fallbackLinkPrice = onchainConfig.fallbackLinkPrice;
    s_fallbackNativePrice = onchainConfig.fallbackNativePrice;

    uint32 previousConfigBlockNumber = s_storage.latestConfigBlockNumber;
    s_storage.latestConfigBlockNumber = uint32(onchainConfig.chainModule.blockNumber());
    s_storage.configCount += 1;

    bytes memory onchainConfigBytes = abi.encode(onchainConfig);

    s_latestConfigDigest = _configDigestFromConfigData(
      block.chainid,
      address(this),
      s_storage.configCount,
      signers,
      transmitters,
      f,
      onchainConfigBytes,
      offchainConfigVersion,
      offchainConfig
    );

    for (uint256 idx = 0; idx < s_registrars.length(); idx++) {
      s_registrars.remove(s_registrars.at(idx));
    }

    for (uint256 idx = 0; idx < onchainConfig.registrars.length; idx++) {
      s_registrars.add(onchainConfig.registrars[idx]);
    }

    emit ConfigSet(
      previousConfigBlockNumber,
      s_latestConfigDigest,
      s_storage.configCount,
      signers,
      transmitters,
      f,
      onchainConfigBytes,
      offchainConfigVersion,
      offchainConfig
    );
  }

  // ================================================================
  // |                           GETTERS                            |
  // ================================================================

  /**
   * @inheritdoc OCR2Abstract
   */
  function latestConfigDetails()
    external
    view
    override
    returns (uint32 configCount, uint32 blockNumber, bytes32 configDigest)
  {
    return (s_storage.configCount, s_storage.latestConfigBlockNumber, s_latestConfigDigest);
  }

  /**
   * @inheritdoc OCR2Abstract
   */
  function latestConfigDigestAndEpoch()
    external
    view
    override
    returns (bool scanLogs, bytes32 configDigest, uint32 epoch)
  {
    return (false, s_latestConfigDigest, s_hotVars.latestEpoch);
  }
}
