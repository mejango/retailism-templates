// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {REVMintConfig} from "./REVMintConfig.sol";

/// @custom:member startsAtOrAfter The timestamp to start a stage at the given rate at or after.
/// @custom:member mintConfigs The configurations of mints during this stage.
/// @custom:member splitPercent The percentage of newly issued tokens that should be split with the operator, out
/// of
/// 10_000 (JBConstants.MAX_RESERVED_RATE).
/// @custom:member initialIssuance The number of revnet tokens that one unit of the revnet's base currency will buy, as a fixed point number
/// with 18 decimals.
/// @custom:member issuanceIncreaseFrequency The number of seconds between applied issuance increases. This
/// should be at least 24 hours.
/// @custom:member issuanceIncreasePercentage The rate at which the issuance should decrease over time. This percentage is out
/// of 1_000_000_000 (JBConstants.MAX_DECAY_RATE). 0% corresponds to no issuance increase.
/// @custom:member cashOutTaxIntensity The factor determining how much each token can cash out from the revnet once
/// redeemed. This percentage is out of 10_000 (JBConstants.MAX_REDEMPTION_RATE). 0% corresponds to no floor tax when
struct REVStageConfig {
    uint40 startsAtOrAfter;
    REVMintConfig[] mintConfigs;
    uint16 splitPercent;
    uint112 initialIssuance;
    uint32 issuanceIncreaseFrequency;
    uint32 issuanceIncreasePercentage;
    uint16 cashOutTaxIntensity;
}
