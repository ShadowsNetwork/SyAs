// SPDX-License-Identifier: MIT
pragma solidity 0.6.11

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
import "./library/AddressResolverUpgradeable.sol"
import "./SafeDecimalMath.sol";

contract Synths is Initializable, OwnableUpgradeable, AddressResolverUpgradeable {
    using SafeMath for uint;
    using SafeDecimalMath for uint;

    uint8 public constant FEE_PERIOD_LENGTH = 6;

    address public feePool;

    // The IssuanceData activity that's happened in a fee period.
    struct IssuanceData {
        uint debtPercentage;
        uint debtEntryIndex;
    }

    mapping(address => uint) lastFeeWithdrawalStorage;

    // The IssuanceData activity that's happened in a fee period.
    mapping(address => IssuanceData[FEE_PERIOD_LENGTH]) public accountIssuanceLedger;

    uint public exchangeFeeRate;

    uint public constant MAX_EXCHANGE_FEE_RATE = SafeDecimalMath.unit() / 10;

    address public constant FEE_ADDRESS = 0x43707C6Bb6202a5E1007356539a925C052EA9767;

    bytes32 private xUSD = "xUSD";

    // This struct represents the issuance activity that's happened in a fee period.
    struct FeePeriod {
        uint64 feePeriodId;
        uint64 startingDebtIndex;
        uint64 startTime;
        uint feesToDistribute;
        uint feesClaimed;
        uint rewardsToDistribute;
        uint rewardsClaimed;
    }

    uint8 public constant FEE_PERIOD_LENGTH = 3;

    FeePeriod[FEE_PERIOD_LENGTH] private _recentFeePeriods;
    uint256 private _currentFeePeriod;

    uint public feePeriodDuration = 1 weeks;

    // The fee period must be between 1 day and 60 days.
    uint public constant MIN_FEE_PERIOD_DURATION = 1 days;
    uint public constant MAX_FEE_PERIOD_DURATION = 60 days;

    // Users are unable to claim fees if their collateralisation ratio drifts out of target treshold
    uint public targetThreshold = (1 * SafeDecimalMath.unit()) / 100;

    function initialize(
        uint _exchangeFeeRate
        address _resolver
    ) external initializer {
        __Ownable_init();
        __AddressResolver_init(_resolver);
        exchangeFeeRate = _exchangeFeeRate;
    }

    function setExchangeFeeRate(uint _exchangeFeeRate) external optionalProxy_onlyOwner {
        require(_exchangeFeeRate < MAX_EXCHANGE_FEE_RATE, "rate < MAX_EXCHANGE_FEE_RATE");
        exchangeFeeRate = _exchangeFeeRate;
    }

    function setFeePeriodDuration(uint _feePeriodDuration) external optionalProxy_onlyOwner {
        require(_feePeriodDuration >= MIN_FEE_PERIOD_DURATION, "value < MIN_FEE_PERIOD_DURATION");
        require(_feePeriodDuration <= MAX_FEE_PERIOD_DURATION, "value > MAX_FEE_PERIOD_DURATION");

        feePeriodDuration = _feePeriodDuration;

        emit FeePeriodDurationUpdated(_feePeriodDuration);
    }

    function setTargetThreshold(uint _percent) external optionalProxy_onlyOwner {
        require(_percent >= 0, "Threshold should be positive");
        require(_percent <= 50, "Threshold too high");
        targetThreshold = _percent.mul(SafeDecimalMath.unit()).div(100);
    }

    function recordFeePaid(uint amount) external onlyExchangerOrSynth {
        // Keep track off fees in xUSD in the open fee pool period.
        _recentFeePeriodsStorage(0).feesToDistribute = _recentFeePeriodsStorage(0).feesToDistribute.add(amount);
    }

    function setRewardsToDistribute(uint amount) external {
        address rewardsAuthority = resolver.getAddress("RewardsDistribution");
        require(messageSender == rewardsAuthority || msg.sender == rewardsAuthority, "Caller is not rewardsAuthority");
        // Add the amount of DOWS rewards to distribute on top of any rolling unclaimed amount
        _recentFeePeriodsStorage(0).rewardsToDistribute = _recentFeePeriodsStorage(0).rewardsToDistribute.add(amount);
    }

    function recentFeePeriods(uint index)
        external
        view
        returns (
            uint64 feePeriodId,
            uint64 startingDebtIndex,
            uint64 startTime,
            uint feesToDistribute,
            uint feesClaimed,
            uint rewardsToDistribute,
            uint rewardsClaimed
        )
    {
        FeePeriod memory feePeriod = _recentFeePeriodsStorage(index);
        return (
            feePeriod.feePeriodId,
            feePeriod.startingDebtIndex,
            feePeriod.startTime,
            feePeriod.feesToDistribute,
            feePeriod.feesClaimed,
            feePeriod.rewardsToDistribute,
            feePeriod.rewardsClaimed
        );
    }

    /**
     * @notice Close the current fee period and start a new one.
     */
    function closeCurrentFeePeriod() external {
        require(_recentFeePeriodsStorage(0).startTime <= (now - feePeriodDuration), "Too early to close fee period");

        FeePeriod storage secondLastFeePeriod = _recentFeePeriodsStorage(FEE_PERIOD_LENGTH - 2);
        FeePeriod storage lastFeePeriod = _recentFeePeriodsStorage(FEE_PERIOD_LENGTH - 1);

        // Any unclaimed fees from the last period in the array roll back one period.
        // Because of the subtraction here, they're effectively proportionally redistributed to those who
        // have already claimed from the old period, available in the new period.
        // The subtraction is important so we don't create a ticking time bomb of an ever growing
        // number of fees that can never decrease and will eventually overflow at the end of the fee pool.
        _recentFeePeriodsStorage(FEE_PERIOD_LENGTH - 2).feesToDistribute = lastFeePeriod
            .feesToDistribute
            .sub(lastFeePeriod.feesClaimed)
            .add(secondLastFeePeriod.feesToDistribute);
        _recentFeePeriodsStorage(FEE_PERIOD_LENGTH - 2).rewardsToDistribute = lastFeePeriod
            .rewardsToDistribute
            .sub(lastFeePeriod.rewardsClaimed)
            .add(secondLastFeePeriod.rewardsToDistribute);

        // Shift the previous fee periods across to make room for the new one.
        _currentFeePeriod = _currentFeePeriod.add(FEE_PERIOD_LENGTH).sub(1).mod(FEE_PERIOD_LENGTH);

        // Clear the first element of the array to make sure we don't have any stale values.
        delete _recentFeePeriods[_currentFeePeriod];

        // Open up the new fee period.
        // Increment periodId from the recent closed period feePeriodId
        _recentFeePeriodsStorage(0).feePeriodId = uint64(uint256(_recentFeePeriodsStorage(1).feePeriodId).add(1));
        _recentFeePeriodsStorage(0).startingDebtIndex = uint64(shadowsState().debtLedgerLength());
        _recentFeePeriodsStorage(0).startTime = uint64(now);

        emit FeePeriodClosed(_recentFeePeriodsStorage(1).feePeriodId);
    }

    function claimFees() external optionalProxy returns (bool) {
        return _claimFees(messageSender);
    }

    function _claimFees(address claimingAddress) internal returns (bool) {
        uint rewardsPaid = 0;
        uint feesPaid = 0;
        uint availableFees;
        uint availableRewards;

        // Address won't be able to claim fees if it is too far below the target c-ratio.
        // It will need to burn synths then try claiming again.
        require(isFeesClaimable(claimingAddress), "C-Ratio below penalty threshold");

        (availableFees, availableRewards) = feesAvailable(claimingAddress);

        require(
            availableFees > 0 || availableRewards > 0,
            "No fees or rewards available for period, or fees already claimed"
        );

        _setLastFeeWithdrawal(claimingAddress, _recentFeePeriodsStorage(1).feePeriodId);

        if (availableFees > 0) {
            feesPaid = _recordFeePayment(availableFees);

            _payFees(claimingAddress, feesPaid);
        }

        if (availableRewards > 0) {
            rewardsPaid = _recordRewardPayment(availableRewards);

            _payRewards(claimingAddress, rewardsPaid);
        }

        emit FeesClaimed(claimingAddress, feesPaid, rewardsPaid);

        return true;
    }

    function isFeesClaimable(address account) public view returns (bool) {
        // Threshold is calculated from ratio % above the target ratio (issuanceRatio).
        //  0  <  10%:   Claimable
        // 10% > above:  Unable to claim
        uint ratio = shadows().collateralisationRatio(account);
        uint targetRatio = shadows().issuanceRatio();

        if (ratio < targetRatio) {
            return true;
        }

        // Calculate the threshold for collateral ratio before fees can't be claimed.
        uint ratio_threshold = targetRatio.multiplyDecimal(SafeDecimalMath.unit().add(targetThreshold));

        // Not claimable if collateral ratio above threshold
        if (ratio > ratio_threshold) {
            return false;
        }

        return true;
    }

    function feesAvailable(address account) public view returns (uint, uint) {
        // Add up the fees
        uint[2][FEE_PERIOD_LENGTH] memory userFees = feesByPeriod(account);

        uint totalFees = 0;
        uint totalRewards = 0;

        // Fees & Rewards in fee period [0] are not yet available for withdrawal
        for (uint i = 1; i < FEE_PERIOD_LENGTH; i++) {
            totalFees = totalFees.add(userFees[i][0]);
            totalRewards = totalRewards.add(userFees[i][1]);
        }

        // And convert totalFees to xUSD
        // Return totalRewards as is in DOWS amount
        return (totalFees, totalRewards);
    }

    function feesByPeriod(address account) public view returns (uint[2][FEE_PERIOD_LENGTH] memory results) {
        // What's the user's debt entry index and the debt they owe to the system at current feePeriod
        uint userOwnershipPercentage;
        uint debtEntryIndex;

        (userOwnershipPercentage, debtEntryIndex) = _getAccountsDebtEntry(account, 0);

        // If they don't have any debt ownership and they never minted, they don't have any fees.
        // User ownership can reduce to 0 if user burns all synths,
        // however they could have fees applicable for periods they had minted in before so we check debtEntryIndex.
        if (debtEntryIndex == 0 && userOwnershipPercentage == 0) return;

        // The [0] fee period is not yet ready to claim, but it is a fee period that they can have
        // fees owing for, so we need to report on it anyway.
        uint feesFromPeriod;
        uint rewardsFromPeriod;
        (feesFromPeriod, rewardsFromPeriod) = _feesAndRewardsFromPeriod(0, userOwnershipPercentage, debtEntryIndex);

        results[0][0] = feesFromPeriod;
        results[0][1] = rewardsFromPeriod;

        // Retrieve user's last fee claim by periodId
        uint lastFeeWithdrawal = getLastFeeWithdrawal(account);

        // Go through our fee periods from the oldest feePeriod[FEE_PERIOD_LENGTH - 1] and figure out what we owe them.
        // Condition checks for periods > 0
        for (uint i = FEE_PERIOD_LENGTH - 1; i > 0; i--) {
            uint next = i - 1;
            uint nextPeriodStartingDebtIndex = _recentFeePeriodsStorage(next).startingDebtIndex;

            // We can skip the period, as no debt minted during period (next period's startingDebtIndex is still 0)
            if (nextPeriodStartingDebtIndex > 0 && lastFeeWithdrawal < _recentFeePeriodsStorage(i).feePeriodId) {
                // We calculate a feePeriod's closingDebtIndex by looking at the next feePeriod's startingDebtIndex
                // we can use the most recent issuanceData[0] for the current feePeriod
                // else find the applicableIssuanceData for the feePeriod based on the StartingDebtIndex of the period
                uint closingDebtIndex = uint256(nextPeriodStartingDebtIndex).sub(1);

                // Gas optimisation - to reuse debtEntryIndex if found new applicable one
                // if applicable is 0,0 (none found) we keep most recent one from issuanceData[0]
                // return if userOwnershipPercentage = 0)
                (userOwnershipPercentage, debtEntryIndex) = _applicableIssuanceData(account, closingDebtIndex);

                (feesFromPeriod, rewardsFromPeriod) = _feesAndRewardsFromPeriod(i, userOwnershipPercentage, debtEntryIndex);

                results[i][0] = feesFromPeriod;
                results[i][1] = rewardsFromPeriod;
            }
        }
    }

    function getLastFeeWithdrawal(address _claimingAddress) public view returns (uint) {
        return lastFeeWithdrawalStorage[_claimingAddress];
    }

    function _setLastFeeWithdrawal(address _claimingAddress, uint _feePeriodID) internal {
        lastFeeWithdrawalStorage[_claimingAddress] = _feePeriodID;
    }

    function _getAccountsDebtEntry(address account, uint index)
        internal
        view
        returns (uint debtPercentage, uint debtEntryIndex)
    {
        require(index < FEE_PERIOD_LENGTH, "index exceeds the FEE_PERIOD_LENGTH");

        debtPercentage = accountIssuanceLedger[account][index].debtPercentage;
        debtEntryIndex = accountIssuanceLedger[account][index].debtEntryIndex;
    }

    function _applicableIssuanceData(address account, uint closingDebtIndex) internal view returns (uint, uint) {
        IssuanceData[FEE_PERIOD_LENGTH] memory issuanceData = accountIssuanceLedger[account];

        // We want to use the user's debtEntryIndex at when the period closed
        // Find the oldest debtEntryIndex for the corresponding closingDebtIndex
        for (uint i = 0; i < FEE_PERIOD_LENGTH; i++) {
            if (closingDebtIndex >= issuanceData[i].debtEntryIndex) {
                return (issuanceData[i].debtPercentage, issuanceData[i].debtEntryIndex);
            }
        }
    }

    function _feesAndRewardsFromPeriod(uint period, uint ownershipPercentage, uint debtEntryIndex)
        internal
        view
        returns (uint, uint)
    {
        // If it's zero, they haven't issued, and they have no fees OR rewards.
        if (ownershipPercentage == 0) return (0, 0);

        uint debtOwnershipForPeriod = ownershipPercentage;

        // If period has closed we want to calculate debtPercentage for the period
        if (period > 0) {
            uint closingDebtIndex = uint256(_recentFeePeriodsStorage(period - 1).startingDebtIndex).sub(1);
            debtOwnershipForPeriod = _effectiveDebtRatioForPeriod(closingDebtIndex, ownershipPercentage, debtEntryIndex);
        }

        // Calculate their percentage of the fees / rewards in this period
        // This is a high precision integer.
        uint feesFromPeriod = _recentFeePeriodsStorage(period).feesToDistribute.multiplyDecimal(debtOwnershipForPeriod);

        uint rewardsFromPeriod = _recentFeePeriodsStorage(period).rewardsToDistribute.multiplyDecimal(
            debtOwnershipForPeriod
        );

        return (feesFromPeriod.preciseDecimalToDecimal(), rewardsFromPeriod.preciseDecimalToDecimal());
    }

    function _recentFeePeriodsStorage(uint index) internal view returns (FeePeriod storage) {
        return _recentFeePeriods[(_currentFeePeriod + index) % FEE_PERIOD_LENGTH];
    }

    function _effectiveDebtRatioForPeriod(uint closingDebtIndex, uint ownershipPercentage, uint debtEntryIndex)
        internal
        view
        returns (uint)
    {
        // Figure out their global debt percentage delta at end of fee Period.
        // This is a high precision integer.
        uint feePeriodDebtOwnership = shadows()
            .debtLedger(closingDebtIndex)
            .divideDecimalRoundPrecise(_shadowsState.debtLedger(debtEntryIndex))
            .multiplyDecimalRoundPrecise(ownershipPercentage);

        return feePeriodDebtOwnership;
    }

    /**
     * @dev onlyIssuer to call me on shadows.issue() & shadows.burn() calls to store the locked DOWS
     * per fee period so we know to allocate the correct proportions of fees and rewards per period
     */
    function appendAccountIssuanceRecord(address account, uint debtRatio, uint debtEntryIndex) external onlyIssuer {
        _appendAccountIssuanceRecord(
            account,
            debtRatio,
            debtEntryIndex,
            _recentFeePeriodsStorage(0).startingDebtIndex
        );

        emit IssuanceDebtRatioEntry(account, debtRatio, debtEntryIndex, _recentFeePeriodsStorage(0).startingDebtIndex);
    }

    function _appendAccountIssuanceRecord(
        address account,
        uint debtRatio,
        uint debtEntryIndex,
        uint currentPeriodStartDebtIndex
    ) internal onlyFeePool {
        // Is the current debtEntryIndex within this fee period
        if (accountIssuanceLedger[account][0].debtEntryIndex < currentPeriodStartDebtIndex) {
            // If its older then shift the previous IssuanceData entries periods down to make room for the new one.
            issuanceDataIndexOrder(account);
        }

        // Always store the latest IssuanceData entry at [0]
        accountIssuanceLedger[account][0].debtPercentage = debtRatio;
        accountIssuanceLedger[account][0].debtEntryIndex = debtEntryIndex;
    }

    function issuanceDataIndexOrder(address account) private {
        for (uint i = FEE_PERIOD_LENGTH - 2; i < FEE_PERIOD_LENGTH; i--) {
            uint next = i + 1;
            accountIssuanceLedger[account][next].debtPercentage = accountIssuanceLedger[account][i].debtPercentage;
            accountIssuanceLedger[account][next].debtEntryIndex = accountIssuanceLedger[account][i].debtEntryIndex;
        }
    }
    
    modifier onlyExchangerOrSynth {
        bool isExchanger = msg.sender == address(exchanger());
        bool isSynth = shadows().synthsByAddress(msg.sender) != bytes32(0);

        require(isExchanger || isSynth, "Only Exchanger, Synths Authorised");
        _;
    }

    modifier onlyIssuer {
        require(msg.sender == address(issuer()), "FeePool: Only Issuer Authorised");
        _;
    }

    modifier onlyExchanger {
        require(msg.sender == address(exchanger()), "FeePool: Only Exchanger Authorised");
        _;
    }

    modifier notFeeAddress(address account) {
        require(account != FEE_ADDRESS, "Fee address not allowed");
        _;
    }

    event FeePeriodDurationUpdated(uint newFeePeriodDuration);

    event IssuanceDebtRatioEntry(
        address account,
        uint debtRatio,
        uint debtEntryIndex,
        uint feePeriodStartingDebtIndex
    );

    event FeePeriodClosed(uint feePeriodId);

    event FeesClaimed(address account, uint xUSDAmount, uint dowsRewards);
}