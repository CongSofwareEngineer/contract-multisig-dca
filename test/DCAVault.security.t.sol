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
        uint8 act = action % 6;
        if (act == 0) {
            try vault.swapExactInputV3(a, b, fee, amount, 1, block.timestamp) {} catch {}
        } else if (act == 5) {
            _tryV4(a, b, fee, f, amount);
        } else if (act == 1) {
            try vault.swapExactInputV3(address(usdc), b, fee, amount, 1, block.timestamp) {} catch {}
        } else if (act == 2) {
            try vault.morphoDeposit(amount) {} catch {}
        } else if (act == 3) {
            // no public Morpho withdraw exists — the raw call must fail and move nothing
            (bool ok,) = address(vault).call(abi.encodeWithSignature("morphoWithdraw(uint256)", amount));
            assertFalse(ok);
        } else {
            try vault.proposeWithdrawBatch(_addrs(a), new uint256[](1), operator) {} catch {}
        }
        vm.stopPrank();

        _assertNothingLeaked();
        _assertNoAllowances();
    }

    /// @dev Split out of the fuzz test to keep its stack small.
    function _tryV4(address a, address b, uint24 fee, uint8 f, uint256 amount) internal {
        int24[3] memory spacings = [TS_LOW, TS_MED, int24(1)];
        try vault.swapExactInputV4(a, b, fee, spacings[f % 3], amount, 1, block.timestamp) {} catch {}
    }

    /// @dev Pool whitelist: any (token, fee, tickSpacing) the signers did not list as one entry is rejected,
    ///      for V3 (tickSpacing = V3_POOL) and V4 alike — the operator cannot route into a pool of its choosing.
    function testFuzz_Security_UnlistedPoolAlwaysRejected(uint24 fee, int24 tickSpacing, bool buyWeth) public {
        address token = buyWeth ? address(weth) : address(cbbtc);
        vm.assume(!vault.allowedPool(token, fee, tickSpacing));
        usdc.mint(address(vault), 1e6);
        vm.startPrank(operator);
        if (tickSpacing == 0) {
            vm.expectRevert(DCAVaultStorage.PoolNotAllowed.selector);
            vault.swapExactInputV3(address(usdc), token, fee, 1e6, 1, block.timestamp);
        }
        vm.expectRevert(DCAVaultStorage.PoolNotAllowed.selector);
        vault.swapExactInputV4(address(usdc), token, fee, tickSpacing, 1e6, 1, block.timestamp);
        vm.stopPrank();
    }

    /// @dev Pool entries are keyed by the stable: after ChangeStableToken, no old (token, fee, tickSpacing) entry
    ///      unlocks the (newStable, token) pool — one nobody vetted and an operator key could create & seed itself.
    function test_Security_ChangeStableTokenDropsOldPoolEntries() public {
        MockERC20 newStable = new MockERC20("New USD", "NUSD", 18);
        MockMorphoVault newVault = _newMorphoVault(newStable);
        _passProposal(
            DCAVaultStorage.ProposalType.ChangeStableToken, abi.encode(address(newStable), address(newVault), treasury)
        );
        assertEq(vault.stableToken(), address(newStable));
        assertFalse(vault.allowedPool(address(weth), FEE_LOW, 0), "old V3 entry must not carry over");
        assertFalse(vault.allowedPool(address(weth), FEE_LOW, TS_LOW), "old V4 entry must not carry over");

        vm.startPrank(operator);
        vm.expectRevert(DCAVaultStorage.PoolNotAllowed.selector);
        vault.swapExactInputV3(address(weth), address(newStable), FEE_LOW, 1 ether, 1, block.timestamp);
        vm.expectRevert(DCAVaultStorage.PoolNotAllowed.selector);
        vault.swapExactInputV4(address(weth), address(newStable), FEE_LOW, TS_LOW, 1 ether, 1, block.timestamp);
        vm.stopPrank();

        // Signers re-vet and whitelist the pool for the new stable explicitly (no Duplicate from the old entry).
        // Next block: proposals created in the switch's own block are expired too (`stableChangedAt`).
        vm.warp(block.timestamp + 1);
        _passProposal(DCAVaultStorage.ProposalType.SetAllowedPool, abi.encode(address(weth), FEE_LOW, int24(0), true));
        assertTrue(vault.allowedPool(address(weth), FEE_LOW, 0));
        assertFalse(vault.allowedPool(address(weth), FEE_LOW, TS_LOW), "only the re-vetted entry is open");
    }

    /// @dev A proposal vetted against the old stable must never execute after ChangeStableToken: a pending
    ///      SetAllowedPool would otherwise open the unvetted (newStable, token) pool, a pending ChangeMorphoVault
    ///      would point the new stable at an old-stable vault. Fresh proposals still work.
    function test_Security_ChangeStableTokenExpiresPendingProposals() public {
        vm.startPrank(signer1);
        uint256 stalePool = vault.proposeSetAllowedPool(address(weth), FEE_LOW, 1, true);
        uint256 staleVault = vault.proposeChangeMorphoVault(address(_newMorphoVault(usdc)));
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        MockERC20 newStable = new MockERC20("New USD", "NUSD", 18);
        MockMorphoVault newVault = _newMorphoVault(newStable);
        _passProposal(
            DCAVaultStorage.ProposalType.ChangeStableToken, abi.encode(address(newStable), address(newVault), treasury)
        );
        assertEq(vault.stableChangedAt(), block.timestamp);

        vm.startPrank(signer2);
        vm.expectRevert(DCAVaultStorage.ProposalExpired.selector);
        vault.approve(stalePool);
        vm.expectRevert(DCAVaultStorage.ProposalExpired.selector);
        vault.approve(staleVault);
        vm.expectRevert(DCAVaultStorage.ProposalExpired.selector);
        vault.reject(stalePool);
        vm.stopPrank();
        (,,,,,, bool expired) = vault.getProposal(stalePool);
        assertTrue(expired, "view reports the stale proposal as expired");
        assertFalse(vault.allowedPool(address(weth), FEE_LOW, 1));
        assertEq(vault.morphoVault(), address(newVault));

        // A proposal created after the switch is unaffected.
        vm.warp(block.timestamp + 1);
        _passProposal(DCAVaultStorage.ProposalType.SetAllowedPool, abi.encode(address(weth), FEE_LOW, int24(1), true));
        assertTrue(vault.allowedPool(address(weth), FEE_LOW, 1));
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
        vm.expectRevert(DCAVaultStorage.NotSigner.selector);
        vault.reject(1);
        vm.expectRevert(DCAVaultStorage.NotSigner.selector);
        vault.cancel(1);
        vm.expectRevert(DCAVaultStorage.NotSigner.selector);
        vault.pause();
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

    function test_Invariant1_V4RouterCannotPullMoreThanAmountIn() public {
        v4Router.setPullExtra(true);
        vm.prank(operator);
        vm.expectRevert("InsufficientAllowance"); // Permit2 allowance is exactly amountIn
        vault.swapExactInputV4(address(weth), address(usdc), FEE_LOW, TS_LOW, 1 ether, 1, block.timestamp);
        assertEq(weth.balanceOf(address(vault)), 5 ether);
    }

    function test_Invariant1_V4ShortOutputIsCaughtByBalanceDelta() public {
        v4Router.setDeliverHalf(true);
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.InsufficientOutput.selector);
        vault.swapExactInputV4(address(weth), address(usdc), FEE_LOW, TS_LOW, 1 ether, 1500e6, block.timestamp);
    }

    /// @dev Permit2 allowance to the UniversalRouter expires in the same block it is granted.
    function test_Invariant3_V4Permit2AllowanceExpiresThisBlock() public {
        vm.prank(operator);
        vault.swapExactInputV4(address(weth), address(usdc), FEE_LOW, TS_LOW, 1 ether, 1, block.timestamp);
        (uint160 amount, uint48 expiration,) = mockPermit2.allowance(address(vault), address(weth), universalRouter);
        assertEq(amount, 0);
        assertLe(expiration, block.timestamp);
    }

    // =========================================================== #2 outputs always to address(this)

    function test_Invariant2_SwapRecipientIsVault() public {
        vm.prank(operator);
        vault.swapExactInputV3(address(cbbtc), address(usdc), FEE_MED, 1e7, 1, block.timestamp);
        assertEq(router.lastRecipient(), address(vault));
        vm.prank(operator);
        vault.swapExactInputV3(address(usdc), address(weth), FEE_LOW, 100e6, 1, block.timestamp);
        assertEq(router.lastRecipient(), address(vault));
        // V4: TAKE_ALL pays msg.sender of the UniversalRouter = the vault; nothing reaches the operator.
        uint256 before = weth.balanceOf(address(vault));
        vm.prank(operator);
        vault.swapExactInputV4(address(usdc), address(weth), FEE_LOW, TS_LOW, 100e6, 1, block.timestamp);
        assertEq(weth.balanceOf(address(vault)), before + 0.05 ether);
        assertEq(weth.balanceOf(operator), 0);
        assertEq(usdc.balanceOf(operator), 0);
        _assertNothingLeaked();
    }

    /// @dev A buy is the only operator path that withdraws from Morpho; the stable lands in the vault, then the router.
    function test_Invariant2_MorphoWithdrawReceiverIsVault() public {
        uint256 sharesBefore = morpho.balanceOf(address(vault));
        vm.prank(operator);
        vault.swapExactInputV3(address(usdc), address(weth), FEE_LOW, 500e6, 1, block.timestamp);
        assertEq(morpho.balanceOf(address(vault)), sharesBefore - 500e6);
        assertEq(usdc.balanceOf(operator), 0);
        assertEq(morpho.balanceOf(operator), 0);
    }

    // =========================================================== #3 no allowance survives a tx

    function test_Invariant3_AllowancesZeroAfterEveryFlow() public {
        vm.startPrank(operator);
        vault.swapExactInputV3(address(usdc), address(weth), FEE_LOW, 100e6, 1, block.timestamp);
        _assertNoAllowances();
        vault.swapExactInputV3(address(weth), address(usdc), FEE_LOW, 1 ether, 1, block.timestamp);
        _assertNoAllowances();
        vault.swapExactInputV3(address(cbbtc), address(usdc), FEE_LOW, 1e7, 1, block.timestamp);
        _assertNoAllowances();
        vault.swapExactInputV4(address(usdc), address(weth), FEE_LOW, TS_LOW, 100e6, 1, block.timestamp);
        _assertNoAllowances();
        vault.swapExactInputV4(address(weth), address(usdc), FEE_MED, TS_MED, 1 ether, 1, block.timestamp);
        _assertNoAllowances();
        usdc.mint(address(vault), 10e6); // idle stable (direct transfer)
        vault.morphoDeposit(10e6);
        _assertNoAllowances();
        vm.stopPrank();

        MockMorphoVault newVault = _newMorphoVault(usdc);
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
        vault.swapExactInputV3(address(usdc), address(weth), FEE_LOW, 1e6, 1, block.timestamp);
        vm.expectRevert(DCAVaultStorage.IsPaused.selector);
        vault.morphoDeposit(1);
        vm.expectRevert(DCAVaultStorage.IsPaused.selector);
        vault.swapExactInputV4(address(usdc), address(weth), 500, 10, 1, 1, block.timestamp);
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
        vault.swapExactInputV3(address(usdc), address(weth), FEE_LOW, 1e6, 1, block.timestamp);
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

    // =========================================================== #10 rejects ETH (except native-ETH V4 buy output)

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

    /// @dev Whitelisting native ETH does not open receive(): it only accepts ETH inside a V4 swap buying ETH.
    function test_Invariant10_RejectsEthWhenNativeWhitelisted() public {
        _passProposal(DCAVaultStorage.ProposalType.AddToken, abi.encode(address(0)));
        v4Router.setRate(address(usdc), address(0), 5e8, 1);
        vm.deal(address(v4Router), 10 ether);
        vm.deal(user, 1 ether);

        vm.prank(user);
        vm.expectRevert(DCAVaultStorage.UnexpectedNative.selector);
        payable(address(vault)).transfer(1 ether);

        // A real native buy works...
        usdc.mint(address(vault), 100e6);
        vm.prank(operator);
        vault.swapExactInputV4(address(usdc), address(0), FEE_LOW, TS_LOW, 100e6, 1, block.timestamp);
        assertEq(address(vault).balance, 0.05 ether);

        // ...and the window closes right after it.
        vm.prank(user);
        vm.expectRevert(DCAVaultStorage.UnexpectedNative.selector);
        payable(address(vault)).transfer(1 ether);
    }

    /// @dev A router pushing ETH during a swap whose output is NOT native ETH is rejected (whole swap reverts).
    function test_Invariant10_RouterCannotPushEthDuringErc20Swap() public {
        vm.deal(address(v4Router), 1 ether);
        v4Router.setPushNative(true);
        usdc.mint(address(vault), 100e6);
        vm.prank(operator);
        vm.expectRevert(bytes("native take failed"));
        vault.swapExactInputV4(address(usdc), address(weth), FEE_LOW, TS_LOW, 100e6, 1, block.timestamp);
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
        vault.swapExactInputV3(address(usdc), address(other), FEE_LOW, 1e6, 1, block.timestamp);
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
        vault.swapExactInputV3(address(usdc), address(weth), FEE_LOW, 100e6, 1, block.timestamp);
        vault.swapExactInputV3(address(weth), address(usdc), FEE_LOW, 1 ether, 1, block.timestamp);
        vault.swapExactInputV3(address(cbbtc), address(usdc), FEE_MED, 1e7, 1, block.timestamp);
        usdc.mint(address(vault), 5e6); // idle stable (direct transfer)
        vault.morphoDeposit(5e6);
        // a junk tokenIn is rejected by the whitelist, never by the junk token's own revert
        vm.expectRevert(DCAVaultStorage.TokenNotAllowed.selector);
        vault.swapExactInputV3(address(junk), address(usdc), FEE_LOW, 1, 1, block.timestamp);
        vm.stopPrank();

        // views
        vault.getBalances();
        vault.totalStable();

        // signers: withdraw + vault migration
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e6;
        amounts[1] = type(uint256).max;
        _passProposal(
            DCAVaultStorage.ProposalType.WithdrawBatch,
            abi.encode(_addrs(address(usdc), address(cbbtc)), amounts, treasury)
        );
        assertEq(usdc.balanceOf(treasury), 100e6);
        MockMorphoVault newVault = _newMorphoVault(usdc);
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
        address[] memory tokens = _addrs(address(weth));
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
            new DCAVaultStorage.PoolConfig[](0)
        );
        evil.arm(address(v));
        usdc.mint(user, 10e6);
        vm.startPrank(user);
        usdc.approve(address(v), 10e6);
        vm.expectRevert(bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        v.depositAndSupply(10e6);
        vm.stopPrank();
    }

    // =========================================================== cancel needs >= 50% rejections

    /// @dev A compromised signer can neither cancel another signer's proposal by rejecting it alone
    ///      nor by spamming new proposals; the honest proposal still executes.
    function test_Security_SingleSignerCannotCancelOthers() public {
        address op2 = makeAddr("op2");
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(op2);

        vm.startPrank(signer3); // malicious
        vault.reject(id);
        for (uint256 i; i < 5; ++i) {
            vault.proposeAddWithdrawAddress(makeAddr(string(abi.encodePacked("spam", vm.toString(i)))));
        }
        vm.expectRevert(DCAVaultStorage.NotProposer.selector);
        vault.cancel(id);
        vm.stopPrank();

        (,,,,, bool cancelled,) = vault.getProposal(id);
        assertFalse(cancelled);
        vm.prank(signer2);
        vault.approve(id);
        assertTrue(vault.isOperator(op2));
    }

    // =========================================================== Morpho vault changes only via multisig

    /// @dev Operator / anyone cannot propose; one signer's vote is below threshold (2 of 3), so the
    ///      Morpho address stays put until a second signer approves.
    function test_Security_ChangeMorphoVaultNeedsThreshold() public {
        _deposit(100e6);
        uint256 total = vault.totalStable();
        MockMorphoVault newVault = _newMorphoVault(usdc);

        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.NotSigner.selector);
        vault.proposeChangeMorphoVault(address(newVault));
        vm.prank(attacker);
        vm.expectRevert(DCAVaultStorage.NotSigner.selector);
        vault.proposeChangeMorphoVault(address(newVault));

        vm.prank(signer1);
        uint256 id = vault.proposeChangeMorphoVault(address(newVault));
        assertEq(vault.morphoVault(), address(morpho), "1 vote must not change the vault");

        vm.prank(attacker);
        vm.expectRevert(DCAVaultStorage.NotSigner.selector);
        vault.approve(id);
        assertEq(vault.morphoVault(), address(morpho));

        vm.prank(signer2);
        vault.approve(id);
        assertEq(vault.morphoVault(), address(newVault));
        assertEq(newVault.balanceOf(address(vault)), total);
    }

    /// @dev Router / Permit2 / UniversalRouter can only change through a threshold proposal.
    function test_Security_ChangeProtocolAddressesNeedThreshold() public {
        address evil = makeAddr("evilRouter");
        address[2] memory outsiders = [operator, attacker];
        for (uint256 i; i < outsiders.length; ++i) {
            vm.startPrank(outsiders[i]);
            vm.expectRevert(DCAVaultStorage.NotSigner.selector);
            vault.proposeChangeUniV3Router(evil);
            vm.expectRevert(DCAVaultStorage.NotSigner.selector);
            vault.proposeChangePermit2(evil);
            vm.expectRevert(DCAVaultStorage.NotSigner.selector);
            vault.proposeChangeUniversalRouter(evil);
            vm.stopPrank();
        }

        vm.startPrank(signer1);
        uint256 a = vault.proposeChangeUniV3Router(evil);
        uint256 b = vault.proposeChangePermit2(evil);
        uint256 c = vault.proposeChangeUniversalRouter(evil);
        vm.stopPrank();
        assertEq(vault.uniV3Router(), address(router), "1 vote must not change the router");
        assertEq(vault.permit2(), permit2);
        assertEq(vault.universalRouter(), universalRouter);

        vm.startPrank(attacker);
        vm.expectRevert(DCAVaultStorage.NotSigner.selector);
        vault.approve(a);
        vm.expectRevert(DCAVaultStorage.NotSigner.selector);
        vault.approve(b);
        vm.expectRevert(DCAVaultStorage.NotSigner.selector);
        vault.approve(c);
        vm.stopPrank();
        assertEq(vault.uniV3Router(), address(router));
    }

    /// @dev After a router switch the old router holds no allowance and cannot pull anything (invariant 3).
    function test_Security_OldRouterHasNoPowerAfterChange() public {
        vm.prank(operator);
        vault.swapExactInputV3(address(usdc), address(weth), FEE_LOW, 100e6, 1, block.timestamp);

        _passProposal(DCAVaultStorage.ProposalType.ChangeUniV3Router, abi.encode(makeAddr("newRouter")));

        address[3] memory toks = [address(usdc), address(weth), address(cbbtc)];
        for (uint256 i; i < toks.length; ++i) {
            assertEq(MockERC20(toks[i]).allowance(address(vault), address(router)), 0, "old router allowance");
        }
        vm.prank(address(router));
        vm.expectRevert();
        weth.transferFrom(address(vault), address(router), 1);
    }

    // =========================================================== funds leave only to whitelisted receivers

    /// @dev Operator can only route USDC <-> whitelisted token; token <-> token is rejected.
    function testFuzz_Security_SwapNeedsUsdcSide(uint8 dir, uint256 amount) public {
        amount = bound(amount, 1, 1e7);
        (address a, address b) = dir % 2 == 0 ? (address(weth), address(cbbtc)) : (address(cbbtc), address(weth));
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.PairNotAllowed.selector);
        vault.swapExactInputV3(a, b, FEE_MED, amount, 1, block.timestamp);
    }

    // =========================================================== helpers

    function _assertNothingLeaked() internal view {
        assertEq(usdc.balanceOf(operator) + usdc.balanceOf(attacker), 0, "usdc leaked");
        assertEq(weth.balanceOf(operator) + weth.balanceOf(attacker), 0, "weth leaked");
        assertEq(cbbtc.balanceOf(operator) + cbbtc.balanceOf(attacker), 0, "cbbtc leaked");
        assertEq(usdc.balanceOf(treasury) + weth.balanceOf(treasury) + cbbtc.balanceOf(treasury), 0, "no withdraw");
    }
}
