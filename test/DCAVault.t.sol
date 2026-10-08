// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VaultTestBase} from "./helpers/VaultTestBase.sol";
import {DCAVault} from "../src/DCAVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMorphoVault} from "./mocks/MockMorphoVault.sol";

/// @notice Unit tests (mocks): constructor, roles, proposals, threshold, limits, deposit/swap flows.
contract DCAVaultTest is VaultTestBase {
    // =================================================================== constructor

    function test_Constructor_InitialState() public view {
        assertEq(vault.usdc(), address(usdc));
        assertEq(vault.uniV3Router(), address(router));
        assertEq(vault.permit2(), permit2);
        assertEq(vault.universalRouter(), universalRouter);
        assertEq(vault.morphoVault(), address(morpho));
        assertEq(vault.getSigners().length, 3);
        assertTrue(vault.isSigner(signer1) && vault.isSigner(signer2) && vault.isSigner(signer3));
        assertTrue(vault.isOperator(operator));
        assertTrue(vault.isWithdrawAddress(treasury));
        assertTrue(vault.allowedToken(address(usdc)) && vault.allowedToken(address(weth)));
        assertTrue(vault.allowedToken(address(cbbtc)));
        assertTrue(vault.allowedFee(500) && vault.allowedFee(3000));
        assertFalse(vault.allowedFee(100));
        assertFalse(vault.paused());
        assertEq(vault.getAllowedTokens().length, 3);
    }

    function test_Revert_Constructor_TooFewSigners() public {
        vm.expectRevert(DCAVault.TooFewSigners.selector);
        _deploy(_addrs(signer1), _addrs(operator), _addrs(treasury));
    }

    function test_Revert_Constructor_DuplicateSigner() public {
        vm.expectRevert(DCAVault.Duplicate.selector);
        _deploy(_addrs(signer1, signer1), _addrs(operator), _addrs(treasury));
    }

    function test_Revert_Constructor_ZeroSigner() public {
        vm.expectRevert(DCAVault.ZeroAddress.selector);
        _deploy(_addrs(signer1, address(0)), _addrs(operator), _addrs(treasury));
    }

    function test_Revert_Constructor_SignerIsOperator() public {
        vm.expectRevert(DCAVault.RoleConflict.selector);
        _deploy(_addrs(signer1, signer2), _addrs(signer2), _addrs(treasury));
    }

    function test_Revert_Constructor_DuplicateOperator() public {
        vm.expectRevert(DCAVault.Duplicate.selector);
        _deploy(_addrs(signer1, signer2), _addrs(operator, operator), _addrs(treasury));
    }

    function test_Revert_Constructor_DuplicateWithdrawAddress() public {
        vm.expectRevert(DCAVault.Duplicate.selector);
        _deploy(_addrs(signer1, signer2), _addrs(operator), _addrs(treasury, treasury));
    }

    function test_Constructor_NoOperatorsAllowed() public {
        DCAVault v = _deploy(_addrs(signer1, signer2), new address[](0), _addrs(treasury));
        assertFalse(v.isOperator(operator));
    }

    function test_Revert_Constructor_ZeroProtocolAddress() public {
        address[] memory tokens = _addrs(address(usdc));
        uint24[] memory fees = new uint24[](0);
        vm.expectRevert(DCAVault.ZeroAddress.selector);
        new DCAVault(
            address(usdc),
            address(0),
            permit2,
            universalRouter,
            address(morpho),
            _addrs(signer1, signer2),
            _addrs(operator),
            _addrs(treasury),
            tokens,
            fees
        );
    }

    function test_Revert_Constructor_VaultAssetMismatch() public {
        MockMorphoVault wethVault = new MockMorphoVault(weth);
        vm.expectRevert(DCAVault.VaultAssetMismatch.selector);
        new DCAVault(
            address(usdc),
            address(router),
            permit2,
            universalRouter,
            address(wethVault),
            _addrs(signer1, signer2),
            _addrs(operator),
            _addrs(treasury),
            _addrs(address(usdc)),
            new uint24[](0)
        );
    }

    function test_Revert_Constructor_UsdcNotInTokens() public {
        vm.expectRevert(DCAVault.UsdcNotAllowed.selector);
        new DCAVault(
            address(usdc),
            address(router),
            permit2,
            universalRouter,
            address(morpho),
            _addrs(signer1, signer2),
            _addrs(operator),
            _addrs(treasury),
            _addrs(address(weth)),
            new uint24[](0)
        );
    }

    function test_Revert_Constructor_DuplicateToken() public {
        vm.expectRevert(DCAVault.Duplicate.selector);
        new DCAVault(
            address(usdc),
            address(router),
            permit2,
            universalRouter,
            address(morpho),
            _addrs(signer1, signer2),
            _addrs(operator),
            _addrs(treasury),
            _addrs(address(usdc), address(usdc)),
            new uint24[](0)
        );
    }

    function test_Revert_Constructor_DuplicateFee() public {
        uint24[] memory fees = new uint24[](2);
        fees[0] = 500;
        fees[1] = 500;
        vm.expectRevert(DCAVault.Duplicate.selector);
        new DCAVault(
            address(usdc),
            address(router),
            permit2,
            universalRouter,
            address(morpho),
            _addrs(signer1, signer2),
            _addrs(operator),
            _addrs(treasury),
            _addrs(address(usdc)),
            fees
        );
    }

    // =================================================================== threshold

    function test_GetThreshold_Table() public {
        assertEq(_deploy(_addrs(signer1, signer2), _addrs(operator), _addrs(treasury)).getThreshold(), 1);
        assertEq(vault.getThreshold(), 2); // 3 signers
        address[] memory four = new address[](4);
        address[] memory five = new address[](5);
        for (uint256 i; i < 5; ++i) {
            address a = makeAddr(string(abi.encodePacked("s", vm.toString(i))));
            five[i] = a;
            if (i < 4) four[i] = a;
        }
        assertEq(_deploy(four, _addrs(operator), _addrs(treasury)).getThreshold(), 2);
        assertEq(_deploy(five, _addrs(operator), _addrs(treasury)).getThreshold(), 3);
    }

    // =================================================================== depositAndSupply

    function test_DepositAndSupply_SuppliesToMorpho() public {
        usdc.mint(user, 1000e6);
        vm.startPrank(user);
        usdc.approve(address(vault), 1000e6);
        vm.expectEmit(true, false, false, true, address(vault));
        emit DCAVault.Deposited(user, 1000e6, 1000e6);
        vault.depositAndSupply(1000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(morpho.balanceOf(address(vault)), 1000e6);
        assertEq(vault.totalUsdc(), 1000e6);
        _assertNoAllowances();
    }

    function test_DepositAndSupply_WorksWhilePaused() public {
        vm.prank(signer1);
        vault.pause();
        _deposit(10e6);
        assertEq(vault.totalUsdc(), 10e6);
    }

    function test_Revert_DepositAndSupply_ZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(DCAVault.ZeroAmount.selector);
        vault.depositAndSupply(0);
    }

    // =================================================================== morphoDeposit / morphoWithdraw

    function test_MorphoDeposit_IdleUsdc() public {
        usdc.mint(address(vault), 50e6); // direct transfer, sits idle
        vm.prank(operator);
        vault.morphoDeposit(50e6);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(morpho.balanceOf(address(vault)), 50e6);
        _assertNoAllowances();
    }

    function test_Revert_MorphoDeposit_InsufficientIdle() public {
        usdc.mint(address(vault), 5e6);
        vm.prank(operator);
        vm.expectRevert(DCAVault.InsufficientBalance.selector);
        vault.morphoDeposit(6e6);
    }

    function test_Revert_MorphoDeposit_ZeroAmount() public {
        vm.prank(operator);
        vm.expectRevert(DCAVault.ZeroAmount.selector);
        vault.morphoDeposit(0);
    }

    function test_MorphoWithdraw_ExactAmountToVault() public {
        _deposit(100e6);
        vm.prank(operator);
        vault.morphoWithdraw(30e6);
        assertEq(usdc.balanceOf(address(vault)), 30e6);
        assertEq(vault.totalUsdc(), 100e6);
    }

    function test_Revert_MorphoWithdraw_NotOperator() public {
        _deposit(100e6);
        vm.prank(signer1);
        vm.expectRevert(DCAVault.NotOperator.selector);
        vault.morphoWithdraw(1e6);
    }

    // =================================================================== swapExactInputV3

    function test_SwapExactInputV3_Buy() public {
        usdc.mint(address(vault), 100e6);
        vm.prank(operator);
        uint256 out = vault.swapExactInputV3(address(usdc), address(weth), FEE_LOW, 100e6, 1, block.timestamp);
        assertEq(out, 0.05 ether);
        assertEq(weth.balanceOf(address(vault)), 0.05 ether);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(router.lastRecipient(), address(vault));
        _assertNoAllowances();
    }

    function test_SwapExactInputV3_SellToUsdcAutoDeposits() public {
        weth.mint(address(vault), 1 ether);
        vm.prank(operator);
        uint256 out = vault.swapExactInputV3(address(weth), address(usdc), FEE_LOW, 1 ether, 1, block.timestamp);
        assertEq(out, 2000e6);
        assertEq(usdc.balanceOf(address(vault)), 0, "sold USDC must not sit idle");
        assertEq(morpho.balanceOf(address(vault)), 2000e6);
        _assertNoAllowances();
    }

    function test_SwapExactInputV3_SellOnlyDepositsProceeds() public {
        usdc.mint(address(vault), 7e6); // pre-existing idle USDC is left untouched
        weth.mint(address(vault), 1 ether);
        vm.prank(operator);
        vault.swapExactInputV3(address(weth), address(usdc), FEE_LOW, 1 ether, 1, block.timestamp);
        assertEq(usdc.balanceOf(address(vault)), 7e6);
        assertEq(morpho.balanceOf(address(vault)), 2000e6);
    }

    function test_SwapExactInputV3_NonUsdcPair() public {
        weth.mint(address(vault), 1 ether);
        vm.prank(operator);
        uint256 out = vault.swapExactInputV3(address(weth), address(cbbtc), FEE_MED, 1 ether, 1, block.timestamp);
        assertEq(out, 2e6);
        assertEq(cbbtc.balanceOf(address(vault)), 2e6);
    }

    function test_Revert_SwapExactInputV3_TokenInNotAllowed() public {
        MockERC20 other = new MockERC20("X", "X", 18);
        vm.prank(operator);
        vm.expectRevert(DCAVault.TokenNotAllowed.selector);
        vault.swapExactInputV3(address(other), address(weth), FEE_LOW, 1, 1, block.timestamp);
    }

    function test_Revert_SwapExactInputV3_TokenOutNotAllowed() public {
        MockERC20 other = new MockERC20("X", "X", 18);
        vm.prank(operator);
        vm.expectRevert(DCAVault.TokenNotAllowed.selector);
        vault.swapExactInputV3(address(usdc), address(other), FEE_LOW, 1, 1, block.timestamp);
    }

    function test_Revert_SwapExactInputV3_SameToken() public {
        vm.prank(operator);
        vm.expectRevert(DCAVault.SameToken.selector);
        vault.swapExactInputV3(address(usdc), address(usdc), FEE_LOW, 1, 1, block.timestamp);
    }

    function test_Revert_SwapExactInputV3_ZeroAmountIn() public {
        vm.prank(operator);
        vm.expectRevert(DCAVault.ZeroAmount.selector);
        vault.swapExactInputV3(address(usdc), address(weth), FEE_LOW, 0, 1, block.timestamp);
    }

    function test_Revert_SwapExactInputV3_ZeroMinOut() public {
        usdc.mint(address(vault), 1e6);
        vm.prank(operator);
        vm.expectRevert(DCAVault.ZeroAmount.selector);
        vault.swapExactInputV3(address(usdc), address(weth), FEE_LOW, 1e6, 0, block.timestamp);
    }

    function test_Revert_SwapExactInputV3_DeadlinePassed() public {
        usdc.mint(address(vault), 1e6);
        vm.warp(1000);
        vm.prank(operator);
        vm.expectRevert(DCAVault.DeadlinePassed.selector);
        vault.swapExactInputV3(address(usdc), address(weth), FEE_LOW, 1e6, 1, 999);
    }

    function test_Revert_SwapExactInputV3_FeeNotAllowed() public {
        usdc.mint(address(vault), 1e6);
        vm.prank(operator);
        vm.expectRevert(DCAVault.FeeNotAllowed.selector);
        vault.swapExactInputV3(address(usdc), address(weth), 10000, 1e6, 1, block.timestamp);
    }

    function test_Revert_SwapExactInputV3_InsufficientBalance() public {
        usdc.mint(address(vault), 1e6);
        vm.prank(operator);
        vm.expectRevert(DCAVault.InsufficientBalance.selector);
        vault.swapExactInputV3(address(usdc), address(weth), FEE_LOW, 2e6, 1, block.timestamp);
    }

    function test_Revert_SwapExactInputV3_SlippageFromRouter() public {
        usdc.mint(address(vault), 1e6);
        vm.prank(operator);
        vm.expectRevert(bytes("Too little received"));
        vault.swapExactInputV3(address(usdc), address(weth), FEE_LOW, 1e6, 1 ether, block.timestamp);
    }

    // =================================================================== withdrawAndSwapV3

    function test_WithdrawAndSwapV3_BuysWithExactMorphoWithdraw() public {
        _deposit(1000e6);
        vm.prank(operator);
        uint256 out = vault.withdrawAndSwapV3(address(cbbtc), FEE_LOW, 100e6, 1, block.timestamp);
        assertEq(out, 1e5); // 100 USDC -> 0.001 cbBTC
        assertEq(cbbtc.balanceOf(address(vault)), 1e5);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.totalUsdc(), 900e6);
        _assertNoAllowances();
    }

    function test_WithdrawAndSwapV3_SwapFailureKeepsUsdcInMorpho() public {
        _deposit(1000e6);
        vm.prank(operator);
        vm.expectRevert(bytes("Too little received"));
        vault.withdrawAndSwapV3(address(weth), FEE_LOW, 100e6, 100 ether, block.timestamp);
        assertEq(morpho.balanceOf(address(vault)), 1000e6);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_Revert_WithdrawAndSwapV3_TokenOutUsdc() public {
        _deposit(10e6);
        vm.prank(operator);
        vm.expectRevert(DCAVault.SameToken.selector);
        vault.withdrawAndSwapV3(address(usdc), FEE_LOW, 1e6, 1, block.timestamp);
    }

    function test_Revert_WithdrawAndSwapV3_ZeroAmount() public {
        vm.prank(operator);
        vm.expectRevert(DCAVault.ZeroAmount.selector);
        vault.withdrawAndSwapV3(address(weth), FEE_LOW, 0, 1, block.timestamp);
    }

    function test_Revert_SwapExactInputV4_NotImplemented() public {
        vm.prank(operator);
        vm.expectRevert(DCAVault.NotImplemented.selector);
        vault.swapExactInputV4(address(usdc), address(weth), 500, 10, 1, 1, block.timestamp);
    }

    // =================================================================== proposal mechanics

    function test_Propose_ProposerAutoApproves() public {
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(makeAddr("op2"));
        assertEq(id, 1);
        assertTrue(vault.hasApproved(id, signer1));
        (,, uint256 approvals, uint256 threshold, bool executed,,) = vault.getProposal(id);
        assertEq(approvals, 1);
        assertEq(threshold, 2);
        assertFalse(executed);
        (,, address proposer,,,) = vault.proposals(id);
        assertEq(proposer, signer1, "helper must keep msg.sender, not the contract");
    }

    function test_Approve_ExecutesAtThreshold() public {
        address op2 = makeAddr("op2");
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(op2);
        vm.prank(signer2);
        vm.expectEmit(true, false, false, false, address(vault));
        emit DCAVault.ProposalExecuted(id);
        vault.approve(id);
        assertTrue(vault.isOperator(op2));
    }

    function test_Propose_ExecutesImmediatelyWithTwoSigners() public {
        DCAVault v = _deploy(_addrs(signer1, signer2), _addrs(operator), _addrs(treasury));
        address op2 = makeAddr("op2");
        vm.prank(signer1);
        v.proposeAddOperator(op2);
        assertTrue(v.isOperator(op2));
    }

    function test_Revert_Propose_NotSigner() public {
        vm.prank(operator);
        vm.expectRevert(DCAVault.NotSigner.selector);
        vault.proposeAddOperator(makeAddr("x"));
    }

    function test_Revert_Approve_NotSigner() public {
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(makeAddr("x"));
        vm.prank(attacker);
        vm.expectRevert(DCAVault.NotSigner.selector);
        vault.approve(id);
    }

    function test_Revert_Approve_Twice() public {
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(makeAddr("x"));
        vm.prank(signer1);
        vm.expectRevert(DCAVault.AlreadyApproved.selector);
        vault.approve(id);
    }

    function test_Revert_Approve_NonExistent() public {
        vm.prank(signer1);
        vm.expectRevert(DCAVault.ProposalNotFound.selector);
        vault.approve(42);
    }

    function test_Cancel_ByProposer() public {
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(makeAddr("x"));
        vm.prank(signer1);
        vault.cancel(id);
        (,,,,, bool cancelled,) = vault.getProposal(id);
        assertTrue(cancelled);
        vm.prank(signer2);
        vm.expectRevert(DCAVault.ProposalIsCancelled.selector);
        vault.approve(id);
    }

    function test_Revert_Cancel_NotProposer() public {
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(makeAddr("x"));
        vm.prank(signer2);
        vm.expectRevert(DCAVault.NotProposer.selector);
        vault.cancel(id);
    }

    function test_Revert_Cancel_AfterExecute() public {
        uint256 id = _passProposal(DCAVault.ProposalType.AddOperator, abi.encode(makeAddr("x")));
        vm.prank(signer1);
        vm.expectRevert(DCAVault.ProposalAlreadyExecuted.selector);
        vault.cancel(id);
    }

    function test_Revert_Approve_Expired() public {
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(makeAddr("x"));
        vm.warp(block.timestamp + 7 days + 1);
        (,,,,,, bool expired) = vault.getProposal(id);
        assertTrue(expired);
        vm.prank(signer2);
        vm.expectRevert(DCAVault.ProposalExpired.selector);
        vault.approve(id);
    }

    function test_Approve_ExactlySevenDaysStillValid() public {
        address x = makeAddr("x");
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(x);
        vm.warp(block.timestamp + 7 days);
        vm.prank(signer2);
        vault.approve(id);
        assertTrue(vault.isOperator(x));
    }

    function test_Revert_Approve_AlreadyExecuted() public {
        uint256 id = _passProposal(DCAVault.ProposalType.AddOperator, abi.encode(makeAddr("x")));
        vm.prank(signer3);
        vm.expectRevert(DCAVault.ProposalAlreadyExecuted.selector);
        vault.approve(id);
    }

    function test_Revert_Propose_MalformedData() public {
        vm.prank(signer1);
        vm.expectRevert();
        vault.propose(DCAVault.ProposalType.AddSigner, hex"1234");
    }

    // =================================================================== proposal types

    function test_Proposal_AddRemoveWithdrawAddress() public {
        address w = makeAddr("w2");
        _passProposal(DCAVault.ProposalType.AddWithdrawAddress, abi.encode(w));
        assertTrue(vault.isWithdrawAddress(w));
        _passProposal(DCAVault.ProposalType.RemoveWithdrawAddress, abi.encode(w));
        assertFalse(vault.isWithdrawAddress(w));
    }

    function test_Revert_Proposal_AddWithdrawAddressZero() public {
        vm.prank(signer1);
        vm.expectRevert(DCAVault.ZeroAddress.selector);
        vault.proposeAddWithdrawAddress(address(0));
    }

    function test_Proposal_AddSigner() public {
        address s4 = makeAddr("signer4");
        _passProposal(DCAVault.ProposalType.AddSigner, abi.encode(s4));
        assertTrue(vault.isSigner(s4));
        assertEq(vault.getSigners().length, 4);
        assertEq(vault.getThreshold(), 2);
    }

    function test_Revert_Proposal_AddSignerThatIsOperator() public {
        vm.prank(signer1);
        vm.expectRevert(DCAVault.RoleConflict.selector);
        vault.proposeAddSigner(operator);
    }

    function test_Revert_Proposal_AddExistingSigner() public {
        vm.prank(signer1);
        vm.expectRevert(DCAVault.RoleConflict.selector);
        vault.proposeAddSigner(signer2);
    }

    function test_Proposal_RemoveSigner() public {
        _passProposal(DCAVault.ProposalType.RemoveSigner, abi.encode(signer3));
        assertFalse(vault.isSigner(signer3));
        assertEq(vault.getSigners().length, 2);
        assertEq(vault.getThreshold(), 1);
    }

    function test_Revert_Proposal_RemoveSignerBelowMin() public {
        _passProposal(DCAVault.ProposalType.RemoveSigner, abi.encode(signer3));
        vm.prank(signer1);
        vm.expectRevert(DCAVault.TooFewSigners.selector);
        vault.proposeRemoveSigner(signer2);
    }

    function test_Proposal_AddRemoveOperator() public {
        address op2 = makeAddr("op2");
        _passProposal(DCAVault.ProposalType.AddOperator, abi.encode(op2));
        assertTrue(vault.isOperator(op2));
        _passProposal(DCAVault.ProposalType.RemoveOperator, abi.encode(op2));
        _passProposal(DCAVault.ProposalType.RemoveOperator, abi.encode(operator));
        assertFalse(vault.isOperator(op2));
        assertFalse(vault.isOperator(operator), "removing every operator is allowed");
    }

    function test_Revert_Proposal_AddOperatorThatIsSigner() public {
        vm.prank(signer1);
        vm.expectRevert(DCAVault.RoleConflict.selector);
        vault.proposeAddOperator(signer3);
    }

    function test_Proposal_AddRemoveToken() public {
        MockERC20 t = new MockERC20("T", "T", 18);
        _passProposal(DCAVault.ProposalType.AddToken, abi.encode(address(t)));
        assertTrue(vault.allowedToken(address(t)));
        assertEq(vault.getAllowedTokens().length, 4);
        _passProposal(DCAVault.ProposalType.RemoveToken, abi.encode(address(t)));
        assertFalse(vault.allowedToken(address(t)));
        assertEq(vault.getAllowedTokens().length, 3);
    }

    function test_Revert_Proposal_RemoveUsdc() public {
        vm.prank(signer1);
        vm.expectRevert(DCAVault.CannotRemoveUsdc.selector);
        vault.proposeRemoveToken(address(usdc));
    }

    function test_Proposal_SetAllowedFee() public {
        _passProposal(DCAVault.ProposalType.SetAllowedFee, abi.encode(uint24(100), true));
        assertTrue(vault.allowedFee(100));
        _passProposal(DCAVault.ProposalType.SetAllowedFee, abi.encode(uint24(500), false));
        assertFalse(vault.allowedFee(500));
        usdc.mint(address(vault), 1e6);
        vm.prank(operator);
        vm.expectRevert(DCAVault.FeeNotAllowed.selector);
        vault.swapExactInputV3(address(usdc), address(weth), 500, 1e6, 1, block.timestamp);
    }

    function test_Revert_Proposal_SetAllowedFeeZero() public {
        vm.prank(signer1);
        vm.expectRevert(DCAVault.InvalidFee.selector);
        vault.proposeSetAllowedFee(0, true);
    }

    function test_Proposal_ChangeMorphoVaultMigrates() public {
        _deposit(1000e6);
        usdc.mint(address(vault), 5e6); // idle USDC also moves into the new vault
        MockMorphoVault newVault = new MockMorphoVault(usdc);

        vm.prank(signer1);
        uint256 id = vault.proposeChangeMorphoVault(address(newVault));
        vm.prank(signer2);
        vm.expectEmit(false, false, false, true, address(vault));
        emit DCAVault.MorphoVaultChanged(address(morpho), address(newVault), 1005e6);
        vault.approve(id);

        assertEq(vault.morphoVault(), address(newVault));
        assertEq(morpho.balanceOf(address(vault)), 0);
        assertEq(newVault.balanceOf(address(vault)), 1005e6);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(usdc.allowance(address(vault), address(newVault)), 0);
        _assertNoAllowances();
    }

    function test_Revert_Proposal_ChangeMorphoVaultWrongAsset() public {
        MockMorphoVault wethVault = new MockMorphoVault(weth);
        vm.prank(signer1);
        vm.expectRevert(DCAVault.VaultAssetMismatch.selector);
        vault.proposeChangeMorphoVault(address(wethVault));
    }

    function test_Revert_Proposal_ChangeMorphoVaultSame() public {
        vm.prank(signer1);
        uint256 id = vault.proposeChangeMorphoVault(address(morpho));
        vm.prank(signer2);
        vm.expectRevert(DCAVault.SameMorphoVault.selector);
        vault.approve(id);
    }

    // =================================================================== WithdrawBatch

    function test_WithdrawBatch_MultipleTokens() public {
        weth.mint(address(vault), 2 ether);
        cbbtc.mint(address(vault), 3e8);
        address[] memory tokens = _addrs(address(weth), address(cbbtc));
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = type(uint256).max;

        vm.prank(signer1);
        uint256 id = vault.proposeWithdrawBatch(tokens, amounts, treasury);
        vm.prank(signer2);
        vault.approve(id);

        assertEq(weth.balanceOf(treasury), 1 ether);
        assertEq(weth.balanceOf(address(vault)), 1 ether);
        assertEq(cbbtc.balanceOf(treasury), 3e8);
        assertEq(cbbtc.balanceOf(address(vault)), 0);
    }

    function test_WithdrawBatch_UsdcPullsShortfallFromMorpho() public {
        _deposit(1000e6);
        usdc.mint(address(vault), 10e6); // idle
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 300e6;
        _passProposal(DCAVault.ProposalType.WithdrawBatch, abi.encode(_addrs(address(usdc)), amounts, treasury));
        assertEq(usdc.balanceOf(treasury), 300e6);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.totalUsdc(), 710e6);
        _assertNoAllowances();
    }

    function test_WithdrawBatch_UsdcIdleOnlyDoesNotTouchMorpho() public {
        _deposit(1000e6);
        usdc.mint(address(vault), 50e6);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 40e6;
        _passProposal(DCAVault.ProposalType.WithdrawBatch, abi.encode(_addrs(address(usdc)), amounts, treasury));
        assertEq(morpho.balanceOf(address(vault)), 1000e6);
        assertEq(usdc.balanceOf(address(vault)), 10e6);
    }

    function test_WithdrawBatch_UsdcMaxRedeemsEverything() public {
        _deposit(1000e6);
        usdc.mint(address(vault), 10e6);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint256).max;
        _passProposal(DCAVault.ProposalType.WithdrawBatch, abi.encode(_addrs(address(usdc)), amounts, treasury));
        assertEq(usdc.balanceOf(treasury), 1010e6);
        assertEq(morpho.balanceOf(address(vault)), 0);
        assertEq(vault.totalUsdc(), 0);
    }

    function test_Revert_WithdrawBatch_ToNotWhitelisted() public {
        weth.mint(address(vault), 1 ether);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        vm.prank(signer1);
        vm.expectRevert(DCAVault.WithdrawAddressNotAllowed.selector);
        vault.proposeWithdrawBatch(_addrs(address(weth)), amounts, attacker);
    }

    function test_Revert_WithdrawBatch_LengthMismatch() public {
        uint256[] memory amounts = new uint256[](2);
        vm.prank(signer1);
        vm.expectRevert(DCAVault.BadArrayLength.selector);
        vault.proposeWithdrawBatch(_addrs(address(weth)), amounts, treasury);
    }

    function test_Revert_WithdrawBatch_Empty() public {
        vm.prank(signer1);
        vm.expectRevert(DCAVault.BadArrayLength.selector);
        vault.proposeWithdrawBatch(new address[](0), new uint256[](0), treasury);
    }

    function test_Revert_WithdrawBatch_ZeroAmount() public {
        vm.prank(signer1);
        vm.expectRevert(DCAVault.ZeroAmount.selector);
        vault.proposeWithdrawBatch(_addrs(address(weth)), new uint256[](1), treasury);
    }

    function test_Revert_WithdrawBatch_InsufficientBalance() public {
        weth.mint(address(vault), 1 ether);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 2 ether;
        vm.prank(signer1);
        uint256 id = vault.proposeWithdrawBatch(_addrs(address(weth)), amounts, treasury);
        vm.prank(signer2);
        vm.expectRevert(DCAVault.InsufficientBalance.selector);
        vault.approve(id);
    }

    function test_Revert_WithdrawBatch_AddressRemovedBeforeExecute() public {
        weth.mint(address(vault), 1 ether);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        vm.prank(signer1);
        uint256 id = vault.proposeWithdrawBatch(_addrs(address(weth)), amounts, treasury);
        _passProposal(DCAVault.ProposalType.RemoveWithdrawAddress, abi.encode(treasury));
        vm.prank(signer2);
        vm.expectRevert(DCAVault.WithdrawAddressNotAllowed.selector);
        vault.approve(id);
    }

    // =================================================================== pause / unpause

    function test_Pause_SingleSigner() public {
        vm.prank(signer3);
        vm.expectEmit(true, false, false, false, address(vault));
        emit DCAVault.Paused(signer3);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_Revert_Pause_NotSigner() public {
        vm.prank(operator);
        vm.expectRevert(DCAVault.NotSigner.selector);
        vault.pause();
    }

    function test_Revert_Pause_AlreadyPaused() public {
        vm.prank(signer1);
        vault.pause();
        vm.prank(signer2);
        vm.expectRevert(DCAVault.IsPaused.selector);
        vault.pause();
    }

    function test_Unpause_ViaProposal() public {
        vm.prank(signer1);
        vault.pause();
        vm.prank(signer1);
        uint256 id = vault.proposeUnpause();
        assertTrue(vault.paused(), "one signer cannot unpause alone");
        vm.prank(signer2);
        vault.approve(id);
        assertFalse(vault.paused());
    }

    function test_Revert_Unpause_WhenNotPaused() public {
        vm.prank(signer1);
        uint256 id = vault.proposeUnpause();
        vm.prank(signer2);
        vm.expectRevert(DCAVault.NotPaused.selector);
        vault.approve(id);
    }

    function test_ProposalsWorkWhilePaused() public {
        weth.mint(address(vault), 1 ether);
        vm.prank(signer1);
        vault.pause();
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        _passProposal(DCAVault.ProposalType.WithdrawBatch, abi.encode(_addrs(address(weth)), amounts, treasury));
        assertEq(weth.balanceOf(treasury), 1 ether);
    }

    // =================================================================== views

    function test_GetBalances() public {
        _deposit(100e6);
        usdc.mint(address(vault), 3e6);
        weth.mint(address(vault), 1 ether);
        cbbtc.mint(address(vault), 5e7);
        (uint256 idle, uint256 inMorpho, address[] memory tokens, uint256[] memory bals) = vault.getBalances();
        assertEq(idle, 3e6);
        assertEq(inMorpho, 100e6);
        assertEq(tokens.length, 3);
        assertEq(tokens[1], address(weth));
        assertEq(bals[0], 3e6);
        assertEq(bals[1], 1 ether);
        assertEq(bals[2], 5e7);
        assertEq(vault.totalUsdc(), 103e6);
    }

    function test_Revert_GetProposal_NotFound() public {
        vm.expectRevert(DCAVault.ProposalNotFound.selector);
        vault.getProposal(0);
    }
}
