// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {mulDiv} from "@prb/math/src/Common.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IJBProjects} from "@bananapus/core/src/interfaces/IJBProjects.sol";
import {IJBPrices} from "@bananapus/core/src/interfaces/IJBPrices.sol";
import {IJBTokens} from "@bananapus/core/src/interfaces/IJBTokens.sol";
import {IJBController} from "@bananapus/core/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core/src/interfaces/IJBTerminal.sol";
import {JBSurplus} from "@bananapus/core/src/libraries/JBSurplus.sol";
import {JBRulesetMetadataResolver} from "@bananapus/core/src/libraries/JBRulesetMetadataResolver.sol";
import {IJBPayoutTerminal} from "@bananapus/core/src/interfaces/IJBPayoutTerminal.sol";
import {JBConstants} from "@bananapus/core/src/libraries/JBConstants.sol";
import {JBSingleAllowance} from "@bananapus/core/src/structs/JBSingleAllowance.sol";
import {JBRuleset} from "@bananapus/core/src/structs/JBRuleset.sol";
import {JBAccountingContext} from "@bananapus/core/src/structs/JBAccountingContext.sol";

import {IREVBasic} from "./interfaces/IREVBasic.sol";
import {IREVLoans} from "./interfaces/IREVLoans.sol";
import {REVLoan} from "./structs/REVLoan.sol";
import {REVLoanSource} from "./structs/REVLoanSource.sol";

/// @notice A contract for borrowing from revnets.
/// @dev Tokens used as collateral are burned, and reminted when the loan is paid off. This keeps the revnet's token
/// structure orderly.
/// @dev The borrowable amount is a linear proportionality between tokens and available funds. This works itself out to
/// maximize the potential of issued loans while still favoring the next cash out rate from the revnet.
/// @dev An upfront fee is taken when a loan is created. 2.5% is charged by the underlying protocol, 2.5% is charged
/// by the
/// revnet issuing the loan, and a variable amount charged by the revnet that receives the fees. This variable amount is chosen by the borrower, the more paid upfront, the longer the prepaid duration. The loan can be repaid anytime
/// within the prepaid duration without additional fees.
/// After the prepaid duration, the loan will increasingly cost more to pay off. After 10 years, the loan collateral cannot be
/// recouped.
contract REVLoans is ERC721, IREVLoans {
    // A library that parses the packed ruleset metadata into a friendlier format.
    using JBRulesetMetadataResolver for JBRuleset;

    // A library that adds default safety checks to ERC20 functionality.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error UNAUTHORIZED();
    error MISSING_VALUES();
    error INVALID_PREPAID_FEE_PERCENT();
    error NOT_ENOUGH_COLLATERAL();
    error PERMIT_ALLOWANCE_NOT_ENOUGH();
    error NO_MSG_VALUE_ALLOWED();
    error LOAN_EXPIRED();
    error CANT_BORROW_MORE_FROM_EXISTING_LOAN();
    error CANT_ADD_MORE_COLLATERAL_TO_EXISTING_LOAN();

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @dev A fee of 10% is charged at the time a loan is created. 2.5% is charged by the underlying protocol, 2.5% is
    /// charged by REV, 5% is charge by the revnet issuing the loan.
    uint256 public constant override REV_PREPAID_FEE = 25; // 2.5%

    /// @dev The maximum amount of a loan that can be prepaid at the time of borrowing, in terms of JBConstants.MAX_FEE.
    uint256 public constant override MAX_PREPAID_PERCENT = 500;

    /// @dev After the prepaid duration, the loan will cost more to pay off. After 10 years, the loan
    /// collateral cannot be recouped. This means paying 50% of the loan amount upfront will pay for having access to the remaining 50% for 10 years,
    /// whereas paying 0% of the loan upfront will cost 100% of the loan amount to be paid off after 10 years. After 10 years with repayment, both loans cost 100% and are liquidated.
    uint256 public constant override LOAN_LIQUIDATION_DURATION = 3650 days;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice Mints ERC-721s that represent project ownership and transfers.
    IJBProjects public immutable override PROJECTS;

    /// @notice The ID of the REV revnet that will receive the fees.
    uint256 public immutable override FEE_REVNET_ID;

    /// @notice The permit2 utility.
    IPermit2 public immutable override PERMIT2;

    /// @notice The amount of loans that have been created.
    uint256 public override numberOfLoans;

    /// @notice The ID of the last revnet that has been successfully liquiditated after passing the duration.
    uint256 public override lastLoanIdLiquidated;

    /// @notice An indication if a revnet currently has outstanding loans from the specified terminal in the specified
    /// token.
    /// @custom:member revnetId The ID of the revnet issuing the loan.
    /// @custom:member terminal The terminal that the loan is issued from.
    /// @custom:member token The token being loaned.
    mapping(uint256 revnetId => mapping(IJBPayoutTerminal terminal => mapping(address token => bool))) public override
        isLoanSourceOf;

    /// @notice The total amount loaned out by a revnet from a specified terminal in a specified token.
    /// @custom:member revnetId The ID of the revnet issuing the loan.
    /// @custom:member terminal The terminal that the loan is issued from.
    /// @custom:member token The token being loaned.
    mapping(uint256 revnetId => mapping(IJBPayoutTerminal terminal => mapping(address token => uint256)))
        public
        override totalBorrowedFrom;

    /// @notice The total amount of collateral supporting a revnet's loans.
    /// @custom:member revnetId The ID of the revnet issuing the loan.
    mapping(uint256 revnetId => uint256) public override totalCollateralOf;

    //*********************************************************************//
    // --------------------- internal stored properties ------------------ //
    //*********************************************************************//

    /// @notice The sources of each revnet's loan.
    /// @custom:member revnetId The ID of the revnet issuing the loan.
    mapping(uint256 revnetId => REVLoanSource[]) public _loanSourcesOf;

    /// @notice The loans.
    /// @custom:member The ID of the loan.
    mapping(uint256 loanId => REVLoan) public _loanOf;

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Get a loan.
    /// @custom:member The ID of the loan.
    function loanOf(uint256 loanId) external view override returns (REVLoan memory) {
        return _loanOf[loanId];
    }

    /// @notice The sources of each revnet's loan.
    /// @custom:member revnetId The ID of the revnet issuing the loan.
    function loanSourcesOf(uint256 revnetId) external view override returns (REVLoanSource[] memory) {
        return _loanSourcesOf[revnetId];
    }

    /// @notice The amount that can be borrowed from a revnet.
    /// @param revnetId The ID of the revnet to check for borrowable assets from.
    /// @param collateral The amount of collateral used to secure the loan.
    /// @return borrowableAmount The amount that can be borrowed from the revnet.
    function borrowableAmountFrom(uint256 revnetId, uint256 collateral) external view returns (uint256) {
        // Keep a reference to the revnet's owner.
        IREVBasic revnetOwner = IREVBasic(PROJECTS.ownerOf(revnetId));

        // Keep a reference to the revnet's controller.
        IJBController controller = revnetOwner.CONTROLLER();

        return _borrowableAmountFrom({
            revnetId: revnetId,
            collateral: collateral,
            pendingAutomintTokens: revnetOwner.totalPendingAutoMintAmountOf(revnetId),
            terminals: controller.DIRECTORY().terminalsOf(revnetId),
            prices: controller.PRICES(),
            tokens: controller.TOKENS()
        });
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    /// @notice Checks this contract's balance of a specific token.
    /// @param token The address of the token to get this contract's balance of.
    /// @return This contract's balance.
    function _balanceOf(address token) internal view returns (uint256) {
        // If the `token` is native, get the native token balance.
        return token == JBConstants.NATIVE_TOKEN ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param projects A contract which mints ERC-721s that represent project ownership and transfers.
    /// @param feeRevnetId The ID of the REV revnet that will receive the fees.
    /// @param permit2 A permit2 utility.
    constructor(IJBProjects projects, uint256 feeRevnetId, IPermit2 permit2) ERC721("REV Loans", "$REVLOAN") {
        PROJECTS = projects;
        FEE_REVNET_ID = feeRevnetId;
        PERMIT2 = permit2;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Open a loan by borrowing from a revnet.
    /// @param revnetId The ID of the revnet being borrowed from.
    /// @param terminal The terminal where the funds will be borrowed from.
    /// @param token The token being borrowed.
    /// @param amount The amount being borrowed.
    /// @param collateral The amount of tokens to use as collateral for the loan.
    /// @param beneficiary The address that'll receive the borrowed funds and the tokens resulting from fee payments.
    /// @param prepaidFeePercent The fee percent that will be charged upfront from the revnet being borrowed from.
    /// Prepaying a fee is cheaper than paying later.
    /// @return loanId The ID of the loan created from borrowing.
    function borrowFrom(
        uint256 revnetId,
        IJBPayoutTerminal terminal,
        address token,
        uint256 amount,
        uint256 collateral,
        address payable beneficiary,
        uint256 prepaidFeePercent
    )
        external
        override
        returns (uint256 loanId)
    {
        // Make sure there is an amount being borrowed.
        if (amount == 0) revert MISSING_VALUES();

        // Make sure the prepaid fee percent is between 0 and 20%. Meaning an 16 year loan can be paid upfront with a
        // payment of 50% of the borrowed assets, the cheapest possible rate.
        if (prepaidFeePercent > MAX_PREPAID_PERCENT) revert INVALID_PREPAID_FEE_PERCENT();

        // Get a reference to the loan ID.
        loanId = ++numberOfLoans;

        // Mint the loan.
        _mint({to: msg.sender, tokenId: loanId});

        // Get a reference to the loan being created.
        REVLoan storage loan = _loanOf[loanId];

        // Set the loan's values.
        loan.revnetId = uint56(revnetId);
        loan.source = REVLoanSource({terminal: terminal, token: token});
        loan.createdAt = uint40(block.timestamp);
        loan.prepaidFeePercent = uint16(prepaidFeePercent);
        loan.prepaidDuration = uint32(mulDiv(prepaidFeePercent, LOAN_LIQUIDATION_DURATION, MAX_PREPAID_PERCENT));

        // Make an empty allowance to satisfy the function.
        JBSingleAllowance memory allowance;

        // Borrow the amount.
        _adjust({
            loan: loan,
            newAmount: amount,
            newCollateral: collateral,
            beneficiary: beneficiary,
            allowance: allowance
        });

        emit Borrow(loanId, revnetId, loan, terminal, token, amount, collateral, beneficiary, msg.sender);
    }

    /// @notice Allows the owner of a loan to pay it back or receive returned collateral no longer necessary to support
    /// the loan.
    /// @param loanId The ID of the loan being adjusted.
    /// @param newAmount The new amount of the loan.
    /// @param newCollateral The new amount of collateral backing the loan.
    /// @param beneficiary The address receiving the returned collateral and any tokens resulting from paying fees.
    /// @param allowance An allowance to faciliate permit2 interactions.
    function payOff(
        uint256 loanId,
        uint256 newAmount,
        uint256 newCollateral,
        address payable beneficiary,
        JBSingleAllowance memory allowance
    )
        external
        payable
        override
    {
        // Make sure only the loan's owner can manage it.
        if (_ownerOf(loanId) != msg.sender) revert UNAUTHORIZED();

        // Keep a reference to the fee being iterated on.
        REVLoan storage loan = _loanOf[loanId];

        // Make sure the amount being paid off is less than the loan's amount.
        if (newAmount > loan.amount) revert CANT_BORROW_MORE_FROM_EXISTING_LOAN();

        // Make sure the amount of collateral being added is less than the loan's collateral.
        if (newCollateral > loan.collateral) revert CANT_ADD_MORE_COLLATERAL_TO_EXISTING_LOAN();

        // Borrow in.
        _adjust({
            loan: loan,
            newAmount: newAmount,
            newCollateral: newCollateral,
            beneficiary: beneficiary,
            allowance: allowance
        });

        // If there's no amount or collateral left, burn the loan.
        if (loan.amount == 0 && loan.collateral == 0) {
            _burn(loanId);
        }

        emit PayOff(loanId, loan, newAmount, newCollateral, beneficiary, msg.sender);
    }

    /// @notice Cleans up any liquiditated loans.
    /// @dev Since loans are created in incremental order, earlier IDs will always be liquidated before later ones.
    /// @param count The amount of loans iterate over since the last liquidated loan.
    function liquidateExpiredLoans(uint256 count) external override {
        // Keep a reference to the loan ID being iterated on.
        uint256 loanId;

        // Keep a reference to the number of loans liquiditated.
        uint256 numberOfLoansLiquidated;

        // Iterate over the desired number of loans to check for liquidation.
        for (uint256 i; i < count; i++) {
            // Get a reference to the loan's ID being iterated on.
            loanId = lastLoanIdLiquidated + i;

            // Get a reference to the loan being iterated on.
            REVLoan memory loan = _loanOf[loanId];

            // If the the loan has passed its liquidation timeframe, liquidate it.
            if (block.timestamp - loan.createdAt > LOAN_LIQUIDATION_DURATION) {
                // Decrement the amount loaned.
                totalBorrowedFrom[loan.revnetId][loan.source.terminal][loan.source.token] -= loan.amount;

                // Decrement the total amount of collateral tokens supporting loans from this revnet.
                totalCollateralOf[loan.revnetId] -= loan.collateral;

                // Burn the loan.
                _burn(loanId);

                // Increment the number of loans liquidated.
                numberOfLoansLiquidated++;

                emit Liquidate(loanId, loan, msg.sender);
            } else {
                // Store the latest liquidated loan.
                if (numberOfLoansLiquidated > 0) lastLoanIdLiquidated += numberOfLoansLiquidated;
                return;
            }
        }
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Allows the owner of a loan to pay it back, add more, or receive returned collateral no longer necessary
    /// to support the loan.
    /// @param loan The loan being adjusted.
    /// @param newAmount The new amount of the loan.
    /// @param newCollateral The new amount of collateral backing the loan.
    /// @param beneficiary The address receiving the returned collateral and any tokens resulting from paying fees.
    /// @param allowance An allowance to faciliate permit2 interactions.
    function _adjust(
        REVLoan storage loan,
        uint256 newAmount,
        uint256 newCollateral,
        address payable beneficiary,
        JBSingleAllowance memory allowance
    )
        internal
    {
        // Keep a reference to the revnet's owner.
        IREVBasic revnetOwner = IREVBasic(PROJECTS.ownerOf(loan.revnetId));

        // Keep a reference to the revnet's controller.
        IJBController controller = revnetOwner.CONTROLLER();

        // Keep a reference to the revnet's directory.
        IJBDirectory directory = controller.DIRECTORY();

        // If the borrowed amount is increasing or the collateral is changing, check that the loan will still be
        // properly collateralized.
        if (
            (newAmount > loan.amount || loan.collateral != newCollateral)
                && _borrowableAmountFrom({
                    revnetId: loan.revnetId,
                    collateral: newCollateral,
                    pendingAutomintTokens: revnetOwner.totalPendingAutoMintAmountOf(loan.revnetId),
                    terminals: directory.terminalsOf(loan.revnetId),
                    prices: controller.PRICES(),
                    tokens: controller.TOKENS()
                }) < newAmount
        ) revert NOT_ENOUGH_COLLATERAL();

        // Add to the loan if needed...
        if (newAmount > loan.amount) {
            _addTo({
                loan: loan,
                amount: newAmount - loan.amount,
                feeTerminal: directory.primaryTerminalOf(FEE_REVNET_ID, loan.source.token),
                beneficiary: beneficiary
            });
            // ... or pay off the loan if needed.
        } else if (loan.amount > newAmount) {
            _payOff({loan: loan, amount: loan.amount - newAmount, beneficiary: beneficiary, allowance: allowance});
        }

        // Add collateral if needed...
        if (newCollateral > loan.collateral) {
            _addCollateralTo({loan: loan, amount: newCollateral - loan.collateral, controller: controller});
            // ... or return collateral if needed.
        } else if (loan.collateral > newCollateral) {
            _returnCollateralFrom({
                loan: loan,
                amount: loan.collateral - newCollateral,
                beneficiary: beneficiary,
                controller: controller
            });
        }

        // Store the loans updated values.
        loan.amount = uint112(newAmount);
        loan.collateral = uint112(newCollateral);
    }

    /// @notice Returns collateral from a loan.
    /// @param loan The loan having its collateral returned from.
    /// @param amount The amount of collateral being returned from the loan.
    /// @param beneficiary The address receiving the returned collateral.
    /// @param controller The controller of the revnet.
    function _returnCollateralFrom(
        REVLoan memory loan,
        uint256 amount,
        address payable beneficiary,
        IJBController controller
    )
        internal
    {
        // Decrement the total amount of collateral tokens.
        totalCollateralOf[loan.revnetId] -= amount;

        // Mint the collateral tokens back to the loan payer.
        // slither-disable-next-line unused-return
        controller.mintTokensOf({
            projectId: loan.revnetId,
            tokenCount: amount,
            beneficiary: beneficiary,
            memo: "Removing collateral from loan",
            useReservedPercent: false
        });
    }

    /// @notice Adds collateral to a loan.
    /// @param loan The loan being added to.
    /// @param amount The new amount of collateral being added to the loan.
    /// @param controller The controller of the revnet.
    function _addCollateralTo(REVLoan memory loan, uint256 amount, IJBController controller) internal {
        // Increment the total amount of collateral tokens.
        totalCollateralOf[loan.revnetId] += amount;

        // Burn the tokens that are tracked as collateral.
        controller.burnTokensOf({
            holder: msg.sender,
            projectId: loan.revnetId,
            tokenCount: amount,
            memo: "Adding collateral to loan"
        });
    }

    /// @notice Pays off a loan.
    /// @param loan The loan being paid off.
    /// @param amount The amount being paid off.
    /// @param beneficiary The address receiving any tokens resulting from paying fees.
    /// @param allowance An allowance to faciliate permit2 interactions.
    function _payOff(
        REVLoan memory loan,
        uint256 amount,
        address payable beneficiary,
        JBSingleAllowance memory allowance
    )
        internal
    {
        // Keep a reference to the time since the loan was created.
        uint256 timeSinceLoanCreated = block.timestamp - loan.createdAt;

        // Keep a reference to the fee that'll be taken.
        uint256 feeAmount;

        // If the loan period has passed the prepaid time frame, take a fee.
        if (timeSinceLoanCreated > loan.prepaidDuration) {
            // If the loan period has passed the liqidation time frame, do not allow loan management.
            if (timeSinceLoanCreated > LOAN_LIQUIDATION_DURATION) revert LOAN_EXPIRED();

            // Calculate the prepaid fee for the amount being paid back.
            uint256 prepaidAmount = mulDiv(amount, loan.prepaidFeePercent, JBConstants.MAX_FEE);

            // Calculate the fee as a linear proportion given the amount of time that has passed.
            feeAmount = mulDiv(amount, timeSinceLoanCreated, LOAN_LIQUIDATION_DURATION) - prepaidAmount;
        }

        // Decrement the total amount of a token being loaned out by the revnet from its terminal.
        totalBorrowedFrom[loan.revnetId][loan.source.terminal][loan.source.token] -= amount;

        // Accept the funds that'll be used to pay off loans.
        uint256 amountPaidIn =
            _acceptFundsFor({token: loan.source.token, amount: amount + feeAmount, allowance: allowance});

        // If the loan is being overpaid, transfer any leftover amount back to the payer.
        if (amountPaidIn > loan.amount + feeAmount) {
            _transferFrom({
                from: address(this),
                to: payable(msg.sender),
                token: loan.source.token,
                amount: amountPaidIn - loan.amount - feeAmount
            });
        }

        // The amount to pay as a fee.
        uint256 payValue = loan.source.token == JBConstants.NATIVE_TOKEN ? feeAmount : 0;

        // Pay the fee.
        // slither-disable-next-line unused-return
        try loan.source.terminal.pay{value: payValue}({
            projectId: loan.revnetId,
            token: loan.source.token,
            amount: feeAmount,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "Fee from loan",
            metadata: bytes(abi.encodePacked(FEE_REVNET_ID))
        }) {} catch (bytes memory) {}

        // The borrowed amount to return to the revnet.
        payValue = loan.source.token == JBConstants.NATIVE_TOKEN ? amount : 0;

        // Add the loaned amount back to the revnet.
        try loan.source.terminal.addToBalanceOf{value: payValue}({
            projectId: loan.revnetId,
            token: loan.source.token,
            amount: amount,
            shouldReturnHeldFees: false,
            memo: "Paying off loan",
            metadata: bytes(abi.encodePacked(loan.revnetId))
        }) {} catch (bytes memory) {}
    }

    /// @notice Add a new amount to the loan that is greater than the previous amount.
    /// @param loan The loan being added to.
    /// @param amount The amount being added to the loan.
    /// @param feeTerminal The terminal that the fee will be paid to.
    /// @param beneficiary The address receiving the returned collateral and any tokens resulting from paying fees.
    function _addTo(
        REVLoan memory loan,
        uint256 amount,
        IJBTerminal feeTerminal,
        address payable beneficiary
    )
        internal
    {
        // Register the source if this is the first time its being used for this revnet.
        if (!isLoanSourceOf[loan.revnetId][loan.source.terminal][loan.source.token]) {
            isLoanSourceOf[loan.revnetId][loan.source.terminal][loan.source.token] = true;
            _loanSourcesOf[loan.revnetId].push(
                REVLoanSource({token: loan.source.token, terminal: loan.source.terminal})
            );
        }

        // Increment the amount of the token borrowed from the revnet from the terminal.
        totalBorrowedFrom[loan.revnetId][loan.source.terminal][loan.source.token] += amount;

        {
            // Get a reference to the accounting context for the source.
            JBAccountingContext memory accountingContext =
                loan.source.terminal.accountingContextForTokenOf({projectId: loan.revnetId, token: loan.source.token});

            // Pull the amount to be loaned out of the revnet. This will incure the protocol fee.
            // slither-disable-next-line unused-return
            loan.source.terminal.useAllowanceOf({
                projectId: loan.revnetId,
                token: loan.source.token,
                amount: amount,
                currency: accountingContext.currency,
                minTokensPaidOut: amount,
                beneficiary: payable(address(this)),
                feeBeneficiary: payable(msg.sender),
                memo: "Lending out to a borrower"
            });
        }

        // Get the amount of additional fee to take for REV.
        uint256 feeAmount = mulDiv(amount, REV_PREPAID_FEE, JBConstants.MAX_FEE);

        // The amount to pay as a fee.
        uint256 payValue = loan.source.token == JBConstants.NATIVE_TOKEN ? feeAmount : 0;

        // Pay the fee. Send the REV to the msg.sender.
        // slither-disable-next-line arbitrary-send-eth,unused-return
        try feeTerminal.pay{value: payValue}({
            projectId: FEE_REVNET_ID,
            token: loan.source.token,
            amount: feeAmount,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "Fee from loan",
            metadata: bytes(abi.encodePacked(loan.revnetId))
        }) {} catch (bytes memory) {}

        // Get the amount of additional fee to take for the revnet issuing the loan.
        feeAmount = mulDiv(amount, loan.prepaidFeePercent, JBConstants.MAX_FEE);

        // The amount to pay as a fee.
        payValue = loan.source.token == JBConstants.NATIVE_TOKEN ? feeAmount : 0;

        // Pay the fee. Add the tokens generated as collateral.
        // slither-disable-next-line unused-return
        try loan.source.terminal.pay{value: payValue}({
            projectId: loan.revnetId,
            token: loan.source.token,
            amount: feeAmount,
            beneficiary: beneficiary,
            minReturnedTokens: 0,
            memo: "Fee from loan",
            metadata: bytes(abi.encodePacked(FEE_REVNET_ID))
        }) {} catch (bytes memory) {}

        // Transfer the remaining balance to the borrower.
        _transferFrom({
            from: address(this),
            to: beneficiary,
            token: loan.source.token,
            amount: _balanceOf(loan.source.token)
        });
    }

    /// @notice Makes sure the provided loan is sufficiently collateralized given the new amounts.
    /// @dev The borrowable amount is a linear proportionality between tokens and available funds.
    /// @param revnetId The ID of the revnet to check for borrowable assets from.
    /// @param collateral The amount of collateral that the loan will be collateralized with.
    /// @param pendingAutomintTokens The amount of tokens pending automint from the revnet.
    /// @param terminals The terminals that the funds are being borrowed from.
    /// @param prices A contract that stores prices for each project.
    /// @return borrowableAmount The amount that can be borrowed from the revnet.
    function _borrowableAmountFrom(
        uint256 revnetId,
        uint256 collateral,
        uint256 pendingAutomintTokens,
        IJBTerminal[] memory terminals,
        IJBPrices prices,
        IJBTokens tokens
    )
        internal
        view
        returns (uint256)
    {
        // Get the surplus of all the revnet's terminals in terms of the native currency.
        uint256 totalSurplus = JBSurplus.currentSurplusOf({
            projectId: revnetId,
            terminals: terminals,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN))
        });

        // Get the total amount the revnet currently has loaned out, in terms of the native currency with 18
        // decimals.
        uint256 totalBorrowed = _totalBorrowedFrom({
            revnetId: revnetId,
            decimals: 18,
            currency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            prices: prices
        });

        // Get the total amount of tokens in circulation.
        uint256 totalSupply = tokens.totalSupplyOf(revnetId);

        // Get a refeerence to the collateral being used to secure loans.
        uint256 totalCollateral = totalCollateralOf[revnetId];

        // Proportional.
        return mulDiv(collateral, totalSurplus + totalBorrowed, totalSupply + totalCollateral + pendingAutomintTokens);
    }

    /// @notice The total borrowed amount from a revnet.
    /// @param revnetId The ID of the revnet to check for borrowed assets from.
    /// @param decimals The decimals the resulting fixed point value will include.
    /// @param currency The currency the resulting value will be in terms of.
    /// @param prices A contract that stores prices for each project.
    /// @return borrowedAmount The total amount borrowed.
    function _totalBorrowedFrom(
        uint256 revnetId,
        uint256 decimals,
        uint256 currency,
        IJBPrices prices
    )
        internal
        view
        returns (uint256 borrowedAmount)
    {
        // Keep a reference to all sources being used to loaned out from this revnet.
        REVLoanSource[] memory sources = _loanSourcesOf[revnetId];

        // Keep a reference to the number of sources being loaned out.
        uint256 numberOfSources = sources.length;

        // Keep a reference to the source being iterated on.
        REVLoanSource memory source;

        // Iterate over all sources being used to loaned out.
        for (uint256 i = 0; i < numberOfSources; i++) {
            // Get a reference to the token being iterated on.
            source = sources[i];

            // Get a reference to the accounting context for the source.
            JBAccountingContext memory accountingContext =
                source.terminal.accountingContextForTokenOf({projectId: revnetId, token: source.token});

            // Normalize the price to the provided currency and decimals.
            uint256 pricePerUnit = accountingContext.currency == currency
                ? 10 ** decimals
                : prices.pricePerUnitOf({
                    projectId: revnetId,
                    pricingCurrency: accountingContext.currency,
                    unitCurrency: currency,
                    decimals: decimals
                });

            // Get a reference to the amount of tokens loaned out.
            uint256 tokensLoaned = totalBorrowedFrom[revnetId][source.terminal][source.token];

            borrowedAmount += mulDiv(tokensLoaned, 10 ** decimals, pricePerUnit);
        }
    }

    /// @notice Transfers tokens.
    /// @param from The address to transfer tokens from.
    /// @param to The address to transfer tokens to.
    /// @param token The address of the token being transfered.
    /// @param amount The amount of tokens to transfer, as a fixed point number with the same number of decimals as the
    /// token.
    function _transferFrom(address from, address payable to, address token, uint256 amount) internal virtual {
        if (from == address(this)) {
            // If the token is native token, assume the `sendValue` standard.
            if (token == JBConstants.NATIVE_TOKEN) return Address.sendValue(to, amount);

            // If the transfer is from this contract, use `safeTransfer`.
            return IERC20(token).safeTransfer(to, amount);
        }

        // If there's sufficient approval, transfer normally.
        if (IERC20(token).allowance(address(from), address(this)) >= amount) {
            return IERC20(token).safeTransferFrom(from, to, amount);
        }

        // Otherwise, attempt to use the `permit2` method.
        PERMIT2.transferFrom(from, to, uint160(amount), token);
    }

    /// @notice Accepts an incoming token.
    /// @param token The token being accepted.
    /// @param amount The number of tokens being accepted.
    /// @param allowance The permit2 context.
    /// @return amount The number of tokens which have been accepted.
    function _acceptFundsFor(
        address token,
        uint256 amount,
        JBSingleAllowance memory allowance
    )
        internal
        returns (uint256)
    {
        // If the token is the native token, override `amount` with `msg.value`.
        if (token == JBConstants.NATIVE_TOKEN) return msg.value;

        // If the token is not native, revert if there is a non-zero `msg.value`.
        if (msg.value != 0) revert NO_MSG_VALUE_ALLOWED();

        // Check if the metadata contains permit data.
        if (allowance.amount != 0) {
            // Make sure the permit allowance is enough for this payment. If not we revert early.
            if (allowance.amount < amount) {
                revert PERMIT_ALLOWANCE_NOT_ENOUGH();
            }

            // Keep a reference to the permit rules.
            IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
                details: IAllowanceTransfer.PermitDetails({
                    token: token,
                    amount: allowance.amount,
                    expiration: allowance.expiration,
                    nonce: allowance.nonce
                }),
                spender: address(this),
                sigDeadline: allowance.sigDeadline
            });

            // Set the allowance to `spend` tokens for the user.
            try PERMIT2.permit({owner: _msgSender(), permitSingle: permitSingle, signature: allowance.signature}) {}
                catch (bytes memory) {}
        }

        // Get a reference to the balance before receiving tokens.
        uint256 balanceBefore = _balanceOf(token);

        // Transfer tokens to this terminal from the msg sender.
        _transferFrom({from: _msgSender(), to: payable(address(this)), token: token, amount: amount});

        // The amount should reflect the change in balance.
        return _balanceOf(token) - balanceBefore;
    }
}
