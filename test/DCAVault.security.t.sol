// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VaultTestBase} from "./helpers/VaultTestBase.sol";
import {DCAVault} from "../src/DCAVault.sol";
import {DCAVaultStorage} from "../src/vault/DCAVaultStorage.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMorphoVault} from "./mocks/MockMorphoVault.sol";
import {JunkToken} from "./mocks/JunkToken.sol";
import {ReentrantMorphoVault} from "./mocks/ReentrantMorphoVault.sol";

/// @notice DCA_VAULT_SPEC.md section 10 invariants — one group per invariant — plus a malicious operator.
contract DCAVaultSecurityTest is VaultTestBase {
    function setUp() public override {
        super.setUp();
        _deposit(10_000e6);
        weth.mint(address(vault), 5 ether);
        cbbtc.mint(address(vault), 1e8);
    }

    // =========================================================== #1 operator cannot move tokens out

    /// @dev Random operator actions with random params: nothing may reach operator / attacker,
    ///      and no allowance may survive the tx.
    function testFuzz_Invariant1_OperatorCannotExtract(uint8 action, uint256 amount, uint8 tIn, uint8 tOut, uint8 f)
        public
    {
        address[4] memory toks = [address(usdc), address(weth), address(cbbtc), attacker];
        uint24[3] memory fees = [uint24(500), uint24(3000), uint24(100)];
        address a = toks[tIn % 4];
        address b = toks[tOut % 4];
        uint24 fee = fees[f % 3];
        amount = bound(amount, 0, 20_000e6);

        vm.startPrank(operator);
        uint8 act = action % 5;
        if (act == 0) {
            try vault.swapExactInputV3(a, b, fee, amount, 1, block.timestamp) {} catch {}
        } else if (act == 1) {
            try vault.withdrawAndSwapV3(b, fee, amount, 1, block.timestamp) {} catch {}
        } else if (act == 2) {
            try vault.morphoDeposit(amount) {} catch {}
        } else if (act == 3) {
            try vault.morphoWithdraw(amount) {} catch {}
        } else {
            try vault.proposeWithdrawBatch(_addrs(a), new uint256[](1), operator) {} catch {}
        }
        vm.stopPrank();

        _assertNothingLeaked();
        _assertNoAllowances();
    }

    function test_Invariant1_OperatorCannotUseSignerFunctions() public {
        vm.startPrank(operator);
        vm.expectRevert(DCAVaultStorage.NotSigner.selector);
        vault.propose(DCAVaultStorage.ProposalType.AddWithdrawAddress, abi.encode(operator));
        vm.expectRevert(DCAVaultStorage.NotSigner.selector);
        vault.proposeWithdrawBatch(_addrs(address(weth)), new uint256[](1), treasury);
        vm.expectRevert(DCAVaultStorage.NotSigner.selector);
        vault.approve(1);
        vm.expectRevert(DCAVaultStorage.NotSigner.selector);
        vault.proposeAddSigner(operator);
        vm.stopPrank();
    }

    function test_Invariant1_RouterCannotPullMoreThanAmountIn() public {
        router.setPullExtra(true);
        vm.prank(operator);
        vm.expectRevert(); // ERC20InsufficientAllowance — allowance is exactly amountIn
        vault.swapExactInputV3(address(weth), address(usdc), FEE_LOW, 1 ether, 1, block.timestamp);
        assertEq(weth.balanceOf(address(vault)), 5 ether);
    }

    function test_Invariant1_LyingRouterIsCaughtByBalanceDelta() public {
        router.setLieAboutOutput(true);
        vm.prank(operator);
        // Router delivers half of what the operator demanded but returns a huge amountOut.
        vm.expectRevert(DCAVaultStorage.InsufficientOutput.selector);
        vault.swapExactInputV3(address(weth), address(usdc), FEE_LOW, 1 ether, 1500e6, block.timestamp);
    }

    // =========================================================== #2 outputs always to address(this)

    function test_Invariant2_SwapRecipientIsVault() public {
        vm.prank(operator);
        vault.swapExactInputV3(address(weth), address(cbbtc), FEE_MED, 1 ether, 1, block.timestamp);
        assertEq(router.lastRecipient(), address(vault));
        vm.prank(operator);
        vault.withdrawAndSwapV3(address(weth), FEE_LOW, 100e6, 1, block.timestamp);
        assertEq(router.lastRecipient(), address(vault));
        _assertNothingLeaked();
    }

    function test_Invariant2_MorphoWithdrawReceiverIsVault() public {
        uint256 before = usdc.balanceOf(address(vault));
        vm.prank(operator);
        vault.morphoWithdraw(500e6);
        assertEq(usdc.balanceOf(address(vault)), before + 500e6);
        assertEq(usdc.balanceOf(operator), 0);
    }

    // =========================================================== #3 no allowance survives a tx

    function test_Invariant3_AllowancesZeroAfterEveryFlow() public {
        vm.startPrank(operator);
        vault.withdrawAndSwapV3(address(weth), FEE_LOW, 100e6, 1, block.timestamp);
        _assertNoAllowances();
        vault.swapExactInputV3(address(weth), address(usdc), FEE_LOW, 1 ether, 1, block.timestamp);
        _assertNoAllowances();
        vault.swapExactInputV3(address(cbbtc), address(usdc), FEE_LOW, 1e7, 1, block.timestamp);
        _assertNoAllowances();
        vault.morphoWithdraw(10e6);
        vault.morphoDeposit(10e6);
        _assertNoAllowances();
        vm.stopPrank();

        MockMorphoVault newVault = new MockMorphoVault(usdc);
        _passProposal(DCAVaultStorage.ProposalType.ChangeMorphoVault, abi.encode(address(newVault)));
        _assertNoAllowances();
        assertEq(usdc.allowance(address(vault), address(newVault)), 0);
    }

    // =========================================================== #4 withdraw only via approved batch

    function test_Invariant4_SingleVoteDoesNotWithdraw() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        vm.prank(signer1);
        vault.proposeWithdrawBatch(_addrs(address(weth)), amounts, treasury);
        assertEq(weth.balanceOf(treasury), 0, "1 of 3 signers is below threshold");
    }

    function test_Invariant4_CannotWithdrawToNonWhitelisted() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.WithdrawAddressNotAllowed.selector);
        vault.proposeWithdrawBatch(_addrs(address(weth)), amounts, signer1);
    }

    function test_Invariant4_CannotWithdrawNonAllowedToken() public {
        MockERC20 other = new MockERC20("O", "O", 18);
        other.mint(address(vault), 1 ether);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.TokenNotAllowed.selector);
        vault.proposeWithdrawBatch(_addrs(address(other)), amounts, treasury);
    }

    function test_Invariant4_TokenRemovedBeforeExecuteBlocksWithdraw() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        vm.prank(signer1);
        uint256 id = vault.proposeWithdrawBatch(_addrs(address(weth)), amounts, treasury);
        _passProposal(DCAVaultStorage.ProposalType.RemoveToken, abi.encode(address(weth)));
        vm.prank(signer2);
        vm.expectRevert(DCAVaultStorage.TokenNotAllowed.selector);
        vault.approve(id);
    }

    // =========================================================== #5 signers never < 2

    function test_Invariant5_CannotDropBelowMinSigners() public {
        _passProposal(DCAVaultStorage.ProposalType.RemoveSigner, abi.encode(signer3));
        assertEq(vault.getSigners().length, 2);
        vm.startPrank(signer1);
        vm.expectRevert(DCAVaultStorage.TooFewSigners.selector);
        vault.proposeRemoveSigner(signer2);
        vm.expectRevert(DCAVaultStorage.TooFewSigners.selector);
        vault.proposeRemoveSigner(signer1);
        vm.stopPrank();
    }

    /// @dev Two RemoveSigner proposals created while there are 3 signers: only one may execute.
    function test_Invariant5_ConcurrentRemovalsCannotBypassMin() public {
        vm.prank(signer1);
        uint256 a = vault.proposeRemoveSigner(signer3);
        vm.prank(signer1);
        uint256 b = vault.proposeRemoveSigner(signer2);
        vm.prank(signer2);
        vault.approve(a); // executes: signers = {1, 2}, threshold 1
        vm.prank(signer2);
        vm.expectRevert(DCAVaultStorage.TooFewSigners.selector);
        vault.approve(b);
        assertEq(vault.getSigners().length, 2);
    }

    // =========================================================== #6 removed signer votes don't count

    function test_Invariant6_RemovedSignerVoteNotCounted() public {
        address signer4 = makeAddr("signer4");
        _passProposal(DCAVaultStorage.ProposalType.AddSigner, abi.encode(signer4)); // 4 signers, threshold 2

        address op2 = makeAddr("op2");
        vm.prank(signer1);
        uint256 pending = vault.proposeAddOperator(op2); // signer1 votes

        // remove signer1 (proposed by signer2, approved by signer3)
        vm.prank(signer2);
        uint256 rm = vault.proposeRemoveSigner(signer1);
        vm.prank(signer3);
        vault.approve(rm);
        assertFalse(vault.isSigner(signer1));

        (,, uint256 approvals, uint256 threshold,,,) = vault.getProposal(pending);
        assertEq(approvals, 0, "signer1's vote must not count");
        assertEq(threshold, 2);

        vm.prank(signer2);
        vault.approve(pending);
        assertFalse(vault.isOperator(op2), "1 valid vote < threshold 2");
        vm.prank(signer3);
        vault.approve(pending);
        assertTrue(vault.isOperator(op2));
    }

    function test_Invariant6_RemovedSignerCannotApprove() public {
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(makeAddr("op2"));
        vm.prank(signer2);
        uint256 rm = vault.proposeRemoveSigner(signer3);
        vm.prank(signer1);
        vault.approve(rm);
        vm.prank(signer3);
        vm.expectRevert(DCAVaultStorage.NotSigner.selector);
        vault.approve(id);
    }

    // =========================================================== #7 expired / executed / cancelled

    function test_Invariant7_ExpiredCannotExecute() public {
        vm.prank(signer1);
        uint256 id = vault.proposeAddWithdrawAddress(attacker);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(signer2);
        vm.expectRevert(DCAVaultStorage.ProposalExpired.selector);
        vault.approve(id);
        assertFalse(vault.isWithdrawAddress(attacker));
    }

    function test_Invariant7_ExecutedCannotReExecute() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        uint256 id = _passProposal(
            DCAVaultStorage.ProposalType.WithdrawBatch, abi.encode(_addrs(address(weth)), amounts, treasury)
        );
        vm.prank(signer3);
        vm.expectRevert(DCAVaultStorage.ProposalAlreadyExecuted.selector);
        vault.approve(id);
        assertEq(weth.balanceOf(treasury), 1 ether);
    }

    function test_Invariant7_CancelledCannotExecute() public {
        vm.prank(signer1);
        uint256 id = vault.proposeAddWithdrawAddress(attacker);
        vm.prank(signer1);
        vault.cancel(id);
        vm.prank(signer2);
        vm.expectRevert(DCAVaultStorage.ProposalIsCancelled.selector);
        vault.approve(id);
        assertFalse(vault.isWithdrawAddress(attacker));
    }

    // =========================================================== #8 pause

    function test_Invariant8_PausedBlocksEveryOperatorFunction() public {
        vm.prank(signer2);
        vault.pause();
        vm.startPrank(operator);
        vm.expectRevert(DCAVaultStorage.IsPaused.selector);
        vault.swapExactInputV3(address(weth), address(usdc), FEE_LOW, 1 ether, 1, block.timestamp);
        vm.expectRevert(DCAVaultStorage.IsPaused.selector);
        vault.withdrawAndSwapV3(address(weth), FEE_LOW, 1e6, 1, block.timestamp);
        vm.expectRevert(DCAVaultStorage.IsPaused.selector);
        vault.morphoDeposit(1);
        vm.expectRevert(DCAVaultStorage.IsPaused.selector);
        vault.morphoWithdraw(1);
        vm.expectRevert(DCAVaultStorage.IsPaused.selector);
        vault.swapExactInputV4(address(usdc), address(weth), 500, 10, 1, 1, block.timestamp);
        vm.stopPrank();
    }

    function test_Invariant8_UnpauseNeedsThreshold() public {
        vm.prank(signer1);
        vault.pause();
        vm.prank(signer1);
        uint256 id = vault.proposeUnpause();
        assertTrue(vault.paused());
        vm.prank(signer3);
        vault.approve(id);
        assertFalse(vault.paused());
        vm.prank(operator);
        vault.morphoWithdraw(1e6);
    }

    // =========================================================== #9 no delegatecall / selfdestruct

    /// @dev Walks the runtime bytecode opcode by opcode (skipping PUSH data and the CBOR metadata).
    function test_Invariant9_NoDelegatecallOrSelfdestruct() public view {
        bytes memory code = address(vault).code;
        uint256 metaLen = (uint256(uint8(code[code.length - 2])) << 8) | uint256(uint8(code[code.length - 1]));
        uint256 end = code.length - metaLen - 2;
        for (uint256 i; i < end; ++i) {
            uint8 op = uint8(code[i]);
            assertTrue(op != 0xf4, "DELEGATECALL found");
            assertTrue(op != 0xff, "SELFDESTRUCT found");
            assertTrue(op != 0xf2, "CALLCODE found");
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f; // skip PUSH1..PUSH32 immediates
        }
    }

    // =========================================================== #10 rejects ETH

    function test_Invariant10_RejectsEth() public {
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertFalse(ok, "plain ETH transfer must revert");
        vm.prank(user);
        (ok,) = address(vault).call{value: 1 ether}(hex"deadbeef");
        assertFalse(ok, "unknown selector with ETH must revert");
        vm.prank(user);
        (ok,) = address(vault).call{value: 1}(abi.encodeCall(vault.depositAndSupply, (1)));
        assertFalse(ok, "non-payable functions reject ETH");
        assertEq(address(vault).balance, 0);
    }

    // =========================================================== #11 only USDC in; whitelist enforced

    function test_Invariant11_NoGenericDeposit() public {
        weth.mint(user, 1 ether);
        vm.startPrank(user);
        weth.approve(address(vault), 1 ether);
        (bool ok,) = address(vault).call(abi.encodeWithSignature("deposit(address,uint256)", address(weth), 1 ether));
        vm.stopPrank();
        assertFalse(ok);
        assertEq(weth.balanceOf(user), 1 ether);
    }

    function test_Invariant11_DepositAndSupplyOnlyPullsUsdc() public {
        uint256 wethBefore = weth.balanceOf(address(vault));
        _deposit(1e6);
        assertEq(weth.balanceOf(address(vault)), wethBefore);
    }

    function test_Invariant11_SwapRejectsNonWhitelisted() public {
        MockERC20 other = new MockERC20("O", "O", 18);
        other.mint(address(vault), 1 ether);
        vm.startPrank(operator);
        vm.expectRevert(DCAVaultStorage.TokenNotAllowed.selector);
        vault.swapExactInputV3(address(other), address(usdc), FEE_LOW, 1 ether, 1, block.timestamp);
        vm.expectRevert(DCAVaultStorage.TokenNotAllowed.selector);
        vault.withdrawAndSwapV3(address(other), FEE_LOW, 1e6, 1, block.timestamp);
        vm.stopPrank();
    }

    // =========================================================== #12 junk tokens are ignored

    /// @dev Junk token whose every function reverts sits in the vault; every main flow must still work.
    function test_Invariant12_JunkTokenDoesNotAffectAnyFlow() public {
        JunkToken junk = new JunkToken();
        junk.airdrop(address(vault), 1e30);

        // anyone
        _deposit(1_000e6);
        // operator
        vm.startPrank(operator);
        vault.withdrawAndSwapV3(address(weth), FEE_LOW, 100e6, 1, block.timestamp);
        vault.swapExactInputV3(address(weth), address(usdc), FEE_LOW, 1 ether, 1, block.timestamp);
        vault.swapExactInputV3(address(weth), address(cbbtc), FEE_MED, 1 ether, 1, block.timestamp);
        vault.morphoWithdraw(5e6);
        vault.morphoDeposit(5e6);
        // a junk tokenIn is rejected by the whitelist, never by the junk token's own revert
        vm.expectRevert(DCAVaultStorage.TokenNotAllowed.selector);
        vault.swapExactInputV3(address(junk), address(usdc), FEE_LOW, 1, 1, block.timestamp);
        vm.stopPrank();

        // views
        vault.getBalances();
        vault.totalUsdc();

        // signers: withdraw + vault migration
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e6;
        amounts[1] = type(uint256).max;
        _passProposal(
            DCAVaultStorage.ProposalType.WithdrawBatch,
            abi.encode(_addrs(address(usdc), address(cbbtc)), amounts, treasury)
        );
        assertEq(usdc.balanceOf(treasury), 100e6);
        MockMorphoVault newVault = new MockMorphoVault(usdc);
        _passProposal(DCAVaultStorage.ProposalType.ChangeMorphoVault, abi.encode(address(newVault)));
        assertEq(vault.morphoVault(), address(newVault));

        // a junk-token withdraw proposal is rejected by the whitelist
        uint256[] memory one = new uint256[](1);
        one[0] = 1;
        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.TokenNotAllowed.selector);
        vault.proposeWithdrawBatch(_addrs(address(junk)), one, treasury);
        _assertNoAllowances();
    }

    // =========================================================== reentrancy (malicious protocol)

    function test_Security_ReentrancyBlocked() public {
        ReentrantMorphoVault evil = new ReentrantMorphoVault(usdc);
        address[] memory tokens = _addrs(address(usdc));
        // the evil vault is made an operator so the only thing stopping it is nonReentrant
        DCAVault v = new DCAVault(
            address(usdc),
            address(router),
            permit2,
            universalRouter,
            address(evil),
            _addrs(signer1, signer2),
            _addrs(address(evil)),
            _addrs(treasury),
            tokens,
            new uint24[](0)
        );
        evil.arm(address(v));
        usdc.mint(user, 10e6);
        vm.startPrank(user);
        usdc.approve(address(v), 10e6);
        vm.expectRevert(bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        v.depositAndSupply(10e6);
        vm.stopPrank();
    }

    // =========================================================== helpers

    function _assertNothingLeaked() internal view {
        assertEq(usdc.balanceOf(operator) + usdc.balanceOf(attacker), 0, "usdc leaked");
        assertEq(weth.balanceOf(operator) + weth.balanceOf(attacker), 0, "weth leaked");
        assertEq(cbbtc.balanceOf(operator) + cbbtc.balanceOf(attacker), 0, "cbbtc leaked");
        assertEq(usdc.balanceOf(treasury) + weth.balanceOf(treasury) + cbbtc.balanceOf(treasury), 0, "no withdraw");
    }
}
