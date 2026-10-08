// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VaultTestBase} from "./helpers/VaultTestBase.sol";
import {DCAVault} from "../src/DCAVault.sol";
import {DCAVaultStorage} from "../src/vault/DCAVaultStorage.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMorphoVault} from "./mocks/MockMorphoVault.sol";
import {MockSwapRouter} from "./mocks/MockSwapRouter.sol";
import {MockPermit2} from "./mocks/MockPermit2.sol";
import {MockUniversalRouter} from "./mocks/MockUniversalRouter.sol";

/// @notice Unit tests (mocks): constructor, roles, proposals, threshold, limits, deposit/swap flows.
contract DCAVaultTest is VaultTestBase {
    // =================================================================== constructor

    function test_Constructor_InitialState() public view {
        assertEq(vault.stableToken(), address(usdc));
        assertEq(vault.uniV3Router(), address(router));
        assertEq(vault.permit2(), permit2);
        assertEq(vault.universalRouter(), universalRouter);
        assertEq(vault.morphoVault(), address(morpho));
        assertEq(vault.getSigners().length, 3);
        assertTrue(vault.isSigner(signer1) && vault.isSigner(signer2) && vault.isSigner(signer3));
        assertTrue(vault.isOperator(operator));
        assertTrue(vault.isWithdrawAddress(treasury));
        assertTrue(vault.allowedToken(address(weth)) && vault.allowedToken(address(cbbtc)));
        assertFalse(vault.allowedToken(address(usdc)), "stable is not in the tradable list");
        assertFalse(vault.allowedToken(address(0)), "native ETH not whitelisted by default");
        assertTrue(vault.allowedFee(500) && vault.allowedFee(3000));
        assertFalse(vault.allowedFee(100));
        assertTrue(vault.allowedTickSpacing(TS_LOW) && vault.allowedTickSpacing(TS_MED));
        assertFalse(vault.allowedTickSpacing(1));
        assertFalse(vault.paused());
        assertEq(vault.getAllowedTokens().length, 2);
    }

    function test_Revert_Constructor_TooFewSigners() public {
        vm.expectRevert(DCAVaultStorage.TooFewSigners.selector);
        _deploy(_addrs(signer1), _addrs(operator), _addrs(treasury));
    }

    function test_Revert_Constructor_DuplicateSigner() public {
        vm.expectRevert(DCAVaultStorage.Duplicate.selector);
        _deploy(_addrs(signer1, signer1), _addrs(operator), _addrs(treasury));
    }

    function test_Revert_Constructor_ZeroSigner() public {
        vm.expectRevert(DCAVaultStorage.ZeroAddress.selector);
        _deploy(_addrs(signer1, address(0)), _addrs(operator), _addrs(treasury));
    }

    function test_Revert_Constructor_SignerIsOperator() public {
        vm.expectRevert(DCAVaultStorage.RoleConflict.selector);
        _deploy(_addrs(signer1, signer2), _addrs(signer2), _addrs(treasury));
    }

    function test_Revert_Constructor_DuplicateOperator() public {
        vm.expectRevert(DCAVaultStorage.Duplicate.selector);
        _deploy(_addrs(signer1, signer2), _addrs(operator, operator), _addrs(treasury));
    }

    function test_Revert_Constructor_DuplicateWithdrawAddress() public {
        vm.expectRevert(DCAVaultStorage.Duplicate.selector);
        _deploy(_addrs(signer1, signer2), _addrs(operator), _addrs(treasury, treasury));
    }

    function test_Constructor_NoOperatorsAllowed() public {
        DCAVault v = _deploy(_addrs(signer1, signer2), new address[](0), _addrs(treasury));
        assertFalse(v.isOperator(operator));
    }

    function test_Revert_Constructor_ZeroProtocolAddress() public {
        address[] memory tokens = _addrs(address(weth));
        uint24[] memory fees = new uint24[](0);
        vm.expectRevert(DCAVaultStorage.ZeroAddress.selector);
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
            fees,
            _tickSpacings()
        );
    }

    function test_Revert_Constructor_StableInTokens() public {
        vm.expectRevert(DCAVaultStorage.StableNotTradable.selector);
        new DCAVault(
            address(usdc),
            address(router),
            permit2,
            universalRouter,
            address(morpho),
            _addrs(signer1, signer2),
            _addrs(operator),
            _addrs(treasury),
            _addrs(address(weth), address(usdc)),
            new uint24[](0),
            _tickSpacings()
        );
    }

    function test_Revert_Constructor_DuplicateToken() public {
        vm.expectRevert(DCAVaultStorage.Duplicate.selector);
        new DCAVault(
            address(usdc),
            address(router),
            permit2,
            universalRouter,
            address(morpho),
            _addrs(signer1, signer2),
            _addrs(operator),
            _addrs(treasury),
            _addrs(address(weth), address(weth)),
            new uint24[](0),
            _tickSpacings()
        );
    }

    function test_Revert_Constructor_DuplicateFee() public {
        uint24[] memory fees = new uint24[](2);
        fees[0] = 500;
        fees[1] = 500;
        vm.expectRevert(DCAVaultStorage.Duplicate.selector);
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
            fees,
            _tickSpacings()
        );
    }

    function test_Revert_Constructor_DuplicateTickSpacing() public {
        int24[] memory ts = new int24[](2);
        ts[0] = 60;
        ts[1] = 60;
        vm.expectRevert(DCAVaultStorage.Duplicate.selector);
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
            new uint24[](0),
            ts
        );
    }

    function test_Revert_Constructor_InvalidTickSpacing() public {
        int24[] memory ts = new int24[](1);
        vm.expectRevert(DCAVaultStorage.InvalidTickSpacing.selector);
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
            new uint24[](0),
            ts
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
        emit DCAVaultStorage.Deposited(user, 1000e6, 1000e6);
        vault.depositAndSupply(1000e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(morpho.balanceOf(address(vault)), 1000e6);
        assertEq(vault.totalStable(), 1000e6);
        _assertNoAllowances();
    }

    function test_DepositAndSupply_WorksWhilePaused() public {
        vm.prank(signer1);
        vault.pause();
        _deposit(10e6);
        assertEq(vault.totalStable(), 10e6);
    }

    function test_Revert_DepositAndSupply_ZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(DCAVaultStorage.ZeroAmount.selector);
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
        vm.expectRevert(DCAVaultStorage.InsufficientBalance.selector);
        vault.morphoDeposit(6e6);
    }

    function test_Revert_MorphoDeposit_ZeroAmount() public {
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.ZeroAmount.selector);
        vault.morphoDeposit(0);
    }

    function test_MorphoWithdraw_ExactAmountToVault() public {
        _deposit(100e6);
        vm.prank(operator);
        vault.morphoWithdraw(30e6);
        assertEq(usdc.balanceOf(address(vault)), 30e6);
        assertEq(vault.totalStable(), 100e6);
    }

    function test_Revert_MorphoWithdraw_NotOperator() public {
        _deposit(100e6);
        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.NotOperator.selector);
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

    function test_SwapExactInputV3_SellCbbtcToUsdc() public {
        cbbtc.mint(address(vault), 1e8);
        vm.prank(operator);
        uint256 out = vault.swapExactInputV3(address(cbbtc), address(usdc), FEE_LOW, 1e8, 1, block.timestamp);
        assertEq(out, 100_000e6);
        assertEq(morpho.balanceOf(address(vault)), 100_000e6);
        _assertNoAllowances();
    }

    /// @dev Only USDC <-> token pools: WETH <-> cbBTC is rejected in both directions.
    function test_Revert_SwapExactInputV3_NonUsdcPair() public {
        weth.mint(address(vault), 1 ether);
        cbbtc.mint(address(vault), 1e8);
        vm.startPrank(operator);
        vm.expectRevert(DCAVaultStorage.PairNotAllowed.selector);
        vault.swapExactInputV3(address(weth), address(cbbtc), FEE_MED, 1 ether, 1, block.timestamp);
        vm.expectRevert(DCAVaultStorage.PairNotAllowed.selector);
        vault.swapExactInputV3(address(cbbtc), address(weth), FEE_MED, 1e8, 1, block.timestamp);
        vm.stopPrank();
        assertEq(weth.balanceOf(address(vault)), 1 ether);
        assertEq(cbbtc.balanceOf(address(vault)), 1e8);
    }

    function test_Revert_SwapExactInputV3_TokenInNotAllowed() public {
        MockERC20 other = new MockERC20("X", "X", 18);
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.TokenNotAllowed.selector);
        vault.swapExactInputV3(address(other), address(usdc), FEE_LOW, 1, 1, block.timestamp);
    }

    function test_Revert_SwapExactInputV3_TokenOutNotAllowed() public {
        MockERC20 other = new MockERC20("X", "X", 18);
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.TokenNotAllowed.selector);
        vault.swapExactInputV3(address(usdc), address(other), FEE_LOW, 1, 1, block.timestamp);
    }

    function test_Revert_SwapExactInputV3_SameToken() public {
        // stable -> stable: the other side (the stable) is never in the tradable list.
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.TokenNotAllowed.selector);
        vault.swapExactInputV3(address(usdc), address(usdc), FEE_LOW, 1, 1, block.timestamp);
    }

    function test_Revert_SwapExactInputV3_ZeroAmountIn() public {
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.ZeroAmount.selector);
        vault.swapExactInputV3(address(usdc), address(weth), FEE_LOW, 0, 1, block.timestamp);
    }

    function test_Revert_SwapExactInputV3_ZeroMinOut() public {
        usdc.mint(address(vault), 1e6);
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.ZeroAmount.selector);
        vault.swapExactInputV3(address(usdc), address(weth), FEE_LOW, 1e6, 0, block.timestamp);
    }

    function test_Revert_SwapExactInputV3_DeadlinePassed() public {
        usdc.mint(address(vault), 1e6);
        vm.warp(1000);
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.DeadlinePassed.selector);
        vault.swapExactInputV3(address(usdc), address(weth), FEE_LOW, 1e6, 1, 999);
    }

    function test_Revert_SwapExactInputV3_FeeNotAllowed() public {
        usdc.mint(address(vault), 1e6);
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.FeeNotAllowed.selector);
        vault.swapExactInputV3(address(usdc), address(weth), 10000, 1e6, 1, block.timestamp);
    }

    function test_Revert_SwapExactInputV3_InsufficientBalance() public {
        usdc.mint(address(vault), 1e6);
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.InsufficientBalance.selector);
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
        assertEq(vault.totalStable(), 900e6);
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

    function test_Revert_WithdrawAndSwapV3_TokenOutStable() public {
        _deposit(10e6);
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.TokenNotAllowed.selector);
        vault.withdrawAndSwapV3(address(usdc), FEE_LOW, 1e6, 1, block.timestamp);
    }

    function test_Revert_WithdrawAndSwapV3_ZeroAmount() public {
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.ZeroAmount.selector);
        vault.withdrawAndSwapV3(address(weth), FEE_LOW, 0, 1, block.timestamp);
    }

    // =================================================================== swapExactInputV4

    function test_SwapExactInputV4_Buy() public {
        usdc.mint(address(vault), 100e6);
        vm.prank(operator);
        vm.expectEmit(true, true, false, true, address(vault));
        emit DCAVaultStorage.Swapped(address(usdc), address(weth), FEE_LOW, 100e6, 0.05 ether, 4);
        uint256 out = vault.swapExactInputV4(address(usdc), address(weth), FEE_LOW, TS_LOW, 100e6, 1, block.timestamp);
        assertEq(out, 0.05 ether);
        assertEq(weth.balanceOf(address(vault)), 0.05 ether);
        assertEq(usdc.balanceOf(address(vault)), 0);
        _assertNoAllowances();
    }

    function test_SwapExactInputV4_BuildsSortedHooklessPoolKey() public {
        usdc.mint(address(vault), 100e6);
        vm.prank(operator);
        vault.swapExactInputV4(address(usdc), address(weth), FEE_MED, TS_MED, 100e6, 1, block.timestamp);
        (address c0, address c1, uint24 fee, int24 ts, address hooks) = v4Router.lastKey();
        assertTrue(c0 < c1, "currencies sorted");
        assertTrue((c0 == address(usdc) && c1 == address(weth)) || (c0 == address(weth) && c1 == address(usdc)));
        assertEq(fee, FEE_MED);
        assertEq(ts, TS_MED);
        assertEq(hooks, address(0), "hooks must be address(0)");
        assertEq(v4Router.lastZeroForOne(), address(usdc) < address(weth));
        assertEq(v4Router.lastActions(), hex"060c0f");
    }

    function test_SwapExactInputV4_SellToUsdcAutoDeposits() public {
        weth.mint(address(vault), 1 ether);
        usdc.mint(address(vault), 7e6); // pre-existing idle USDC is left untouched
        vm.prank(operator);
        uint256 out = vault.swapExactInputV4(address(weth), address(usdc), FEE_LOW, TS_LOW, 1 ether, 1, block.timestamp);
        assertEq(out, 2000e6);
        assertEq(usdc.balanceOf(address(vault)), 7e6);
        assertEq(morpho.balanceOf(address(vault)), 2000e6);
        _assertNoAllowances();
    }

    function test_SwapExactInputV4_SellCbbtcToUsdc() public {
        cbbtc.mint(address(vault), 1e8);
        vm.prank(operator);
        uint256 out = vault.swapExactInputV4(address(cbbtc), address(usdc), FEE_LOW, TS_LOW, 1e8, 1, block.timestamp);
        assertEq(out, 100_000e6);
        assertEq(morpho.balanceOf(address(vault)), 100_000e6);
        _assertNoAllowances();
    }

    function test_Revert_SwapExactInputV4_TickSpacingNotAllowed() public {
        usdc.mint(address(vault), 1e6);
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.TickSpacingNotAllowed.selector);
        vault.swapExactInputV4(address(usdc), address(weth), FEE_LOW, 1, 1e6, 1, block.timestamp);
    }

    function test_Revert_SwapExactInputV4_FeeNotAllowed() public {
        usdc.mint(address(vault), 1e6);
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.FeeNotAllowed.selector);
        vault.swapExactInputV4(address(usdc), address(weth), 100, TS_LOW, 1e6, 1, block.timestamp);
    }

    function test_Revert_SwapExactInputV4_NonUsdcPair() public {
        weth.mint(address(vault), 1 ether);
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.PairNotAllowed.selector);
        vault.swapExactInputV4(address(weth), address(cbbtc), FEE_LOW, TS_LOW, 1 ether, 1, block.timestamp);
    }

    function test_Revert_SwapExactInputV4_TokenNotAllowed() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        usdc.mint(address(vault), 1e6);
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.TokenNotAllowed.selector);
        vault.swapExactInputV4(address(usdc), address(other), FEE_LOW, TS_LOW, 1e6, 1, block.timestamp);
    }

    function test_Revert_SwapExactInputV4_ZeroMinOut() public {
        usdc.mint(address(vault), 1e6);
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.ZeroAmount.selector);
        vault.swapExactInputV4(address(usdc), address(weth), FEE_LOW, TS_LOW, 1e6, 0, block.timestamp);
    }

    function test_Revert_SwapExactInputV4_DeadlinePassed() public {
        usdc.mint(address(vault), 1e6);
        vm.warp(1000);
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.DeadlinePassed.selector);
        vault.swapExactInputV4(address(usdc), address(weth), FEE_LOW, TS_LOW, 1e6, 1, 999);
    }

    function test_Revert_SwapExactInputV4_InsufficientBalance() public {
        usdc.mint(address(vault), 1e6);
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.InsufficientBalance.selector);
        vault.swapExactInputV4(address(usdc), address(weth), FEE_LOW, TS_LOW, 1e6 + 1, 1, block.timestamp);
    }

    function test_Revert_SwapExactInputV4_AmountTooLarge() public {
        uint256 big = uint256(type(uint128).max) + 1;
        weth.mint(address(vault), big);
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.AmountTooLarge.selector);
        vault.swapExactInputV4(address(weth), address(usdc), FEE_LOW, TS_LOW, big, 1, block.timestamp);
    }

    function test_Revert_SwapExactInputV4_NotOperator() public {
        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.NotOperator.selector);
        vault.swapExactInputV4(address(usdc), address(weth), FEE_LOW, TS_LOW, 1e6, 1, block.timestamp);
    }

    function test_Revert_SwapExactInputV4_SlippageFromRouter() public {
        usdc.mint(address(vault), 100e6);
        vm.prank(operator);
        vm.expectRevert("V4TooLittleReceived");
        vault.swapExactInputV4(address(usdc), address(weth), FEE_LOW, TS_LOW, 100e6, 0.05 ether + 1, block.timestamp);
    }

    function test_SwapExactInputV4_UsesCurrentRouterAddresses() public {
        MockPermit2 p2 = new MockPermit2();
        MockUniversalRouter ur = new MockUniversalRouter(p2);
        ur.setRate(address(usdc), address(weth), 5e8, 1);
        _passProposal(DCAVaultStorage.ProposalType.ChangePermit2, abi.encode(address(p2)));
        _passProposal(DCAVaultStorage.ProposalType.ChangeUniversalRouter, abi.encode(address(ur)));
        usdc.mint(address(vault), 10e6);
        vm.prank(operator);
        vault.swapExactInputV4(address(usdc), address(weth), FEE_LOW, TS_LOW, 10e6, 1, block.timestamp);
        assertEq(usdc.balanceOf(address(ur)), 10e6, "new router got tokenIn");
        assertEq(usdc.allowance(address(vault), address(p2)), 0);
        (uint160 amt,,) = p2.allowance(address(vault), address(usdc), address(ur));
        assertEq(amt, 0);
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
        emit DCAVaultStorage.ProposalExecuted(id);
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
        vm.expectRevert(DCAVaultStorage.NotSigner.selector);
        vault.proposeAddOperator(makeAddr("x"));
    }

    function test_Revert_Approve_NotSigner() public {
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(makeAddr("x"));
        vm.prank(attacker);
        vm.expectRevert(DCAVaultStorage.NotSigner.selector);
        vault.approve(id);
    }

    function test_Revert_Approve_Twice() public {
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(makeAddr("x"));
        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.AlreadyApproved.selector);
        vault.approve(id);
    }

    function test_Revert_Approve_NonExistent() public {
        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.ProposalNotFound.selector);
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
        vm.expectRevert(DCAVaultStorage.ProposalIsCancelled.selector);
        vault.approve(id);
    }

    function test_Revert_Cancel_NotProposer() public {
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(makeAddr("x"));
        vm.prank(signer2);
        vm.expectRevert(DCAVaultStorage.NotProposer.selector);
        vault.cancel(id);
    }

    function test_Revert_Cancel_ProposerNoLongerSigner() public {
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(makeAddr("x"));
        vm.prank(signer2);
        uint256 rm = vault.proposeRemoveSigner(signer1);
        vm.prank(signer3);
        vault.approve(rm);

        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.NotSigner.selector);
        vault.cancel(id);
        (,,,,, bool cancelled,) = vault.getProposal(id);
        assertFalse(cancelled);
    }

    function test_Revert_Cancel_AfterExecute() public {
        uint256 id = _passProposal(DCAVaultStorage.ProposalType.AddOperator, abi.encode(makeAddr("x")));
        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.ProposalAlreadyExecuted.selector);
        vault.cancel(id);
    }

    function test_Revert_Approve_Expired() public {
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(makeAddr("x"));
        vm.warp(block.timestamp + 7 days + 1);
        (,,,,,, bool expired) = vault.getProposal(id);
        assertTrue(expired);
        vm.prank(signer2);
        vm.expectRevert(DCAVaultStorage.ProposalExpired.selector);
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
        uint256 id = _passProposal(DCAVaultStorage.ProposalType.AddOperator, abi.encode(makeAddr("x")));
        vm.prank(signer3);
        vm.expectRevert(DCAVaultStorage.ProposalAlreadyExecuted.selector);
        vault.approve(id);
    }

    function test_Revert_Propose_MalformedData() public {
        vm.prank(signer1);
        vm.expectRevert();
        vault.propose(DCAVaultStorage.ProposalType.AddSigner, hex"1234");
    }

    // =================================================================== reject (>= 50% "no" cancels)

    function test_Reject_CancelsAtThreshold() public {
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(makeAddr("x"));
        vm.prank(signer2);
        vm.expectEmit(true, true, false, false, address(vault));
        emit DCAVaultStorage.ProposalRejected(id, signer2);
        vault.reject(id);
        assertEq(vault.getRejections(id), 1);
        (,,,,, bool cancelled,) = vault.getProposal(id);
        assertFalse(cancelled, "1 of 3 rejecting is below threshold 2");

        vm.prank(signer3);
        vm.expectEmit(true, false, false, false, address(vault));
        emit DCAVaultStorage.ProposalCancelled(id);
        vault.reject(id);
        (,,,,, cancelled,) = vault.getProposal(id);
        assertTrue(cancelled);
        assertFalse(vault.isOperator(makeAddr("x")));
    }

    /// @dev 4 signers: exactly 50% (2) rejecting is enough.
    function test_Reject_FourSignersHalfCancels() public {
        address s4 = makeAddr("signer4");
        _passProposal(DCAVaultStorage.ProposalType.AddSigner, abi.encode(s4));
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(makeAddr("x"));
        vm.prank(signer2);
        vault.reject(id);
        vm.prank(s4);
        vault.reject(id);
        (,,,,, bool cancelled,) = vault.getProposal(id);
        assertTrue(cancelled);
    }

    function test_Reject_CancelledCannotBeApproved() public {
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(makeAddr("x"));
        vm.prank(signer2);
        vault.reject(id);
        vm.prank(signer3);
        vault.reject(id);
        vm.prank(signer2);
        vm.expectRevert(DCAVaultStorage.ProposalIsCancelled.selector);
        vault.approve(id);
    }

    /// @dev A new proposal never touches pending ones (no single-signer cancel by spamming proposals).
    function test_Propose_DoesNotCancelOtherPending() public {
        vm.prank(signer1);
        uint256 a = vault.proposeAddOperator(makeAddr("x"));
        vm.prank(signer2);
        vault.proposeAddWithdrawAddress(makeAddr("w2"));
        (,,,,, bool cancelled,) = vault.getProposal(a);
        assertFalse(cancelled);
        vm.prank(signer3);
        vault.approve(a);
        assertTrue(vault.isOperator(makeAddr("x")));
    }

    /// @dev A removed signer's rejection stops counting (live re-count, like approvals).
    function test_Reject_RemovedSignerRejectionNotCounted() public {
        address s4 = makeAddr("signer4");
        _passProposal(DCAVaultStorage.ProposalType.AddSigner, abi.encode(s4)); // 4 signers, threshold 2
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(makeAddr("x"));
        vm.prank(s4);
        vault.reject(id);
        _passProposal(DCAVaultStorage.ProposalType.RemoveSigner, abi.encode(s4)); // back to 3, threshold 2
        assertEq(vault.getRejections(id), 0);
        vm.prank(signer3);
        vault.reject(id);
        (,,,,, bool cancelled,) = vault.getProposal(id);
        assertFalse(cancelled, "only 1 valid rejection");
    }

    function test_Revert_Reject_NotSigner() public {
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(makeAddr("x"));
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.NotSigner.selector);
        vault.reject(id);
    }

    function test_Revert_Reject_Twice() public {
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(makeAddr("x"));
        vm.startPrank(signer2);
        vault.reject(id);
        vm.expectRevert(DCAVaultStorage.AlreadyVoted.selector);
        vault.reject(id);
        vm.stopPrank();
    }

    /// @dev One vote per signer: the proposer (auto-approved) cannot also reject.
    function test_Revert_Reject_AfterApprove() public {
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(makeAddr("x"));
        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.AlreadyVoted.selector);
        vault.reject(id);
    }

    function test_Revert_Approve_AfterReject() public {
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(makeAddr("x"));
        vm.startPrank(signer2);
        vault.reject(id);
        vm.expectRevert(DCAVaultStorage.AlreadyVoted.selector);
        vault.approve(id);
        vm.stopPrank();
    }

    function test_Revert_Reject_Expired() public {
        vm.prank(signer1);
        uint256 id = vault.proposeAddOperator(makeAddr("x"));
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(signer2);
        vm.expectRevert(DCAVaultStorage.ProposalExpired.selector);
        vault.reject(id);
    }

    function test_Revert_Reject_AlreadyExecuted() public {
        uint256 id = _passProposal(DCAVaultStorage.ProposalType.AddOperator, abi.encode(makeAddr("x")));
        vm.prank(signer3);
        vm.expectRevert(DCAVaultStorage.ProposalAlreadyExecuted.selector);
        vault.reject(id);
    }

    function test_Revert_Reject_NonExistent() public {
        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.ProposalNotFound.selector);
        vault.reject(42);
        vm.expectRevert(DCAVaultStorage.ProposalNotFound.selector);
        vault.getRejections(42);
    }

    // =================================================================== proposal types

    function test_Proposal_AddRemoveWithdrawAddress() public {
        address w = makeAddr("w2");
        _passProposal(DCAVaultStorage.ProposalType.AddWithdrawAddress, abi.encode(w));
        assertTrue(vault.isWithdrawAddress(w));
        _passProposal(DCAVaultStorage.ProposalType.RemoveWithdrawAddress, abi.encode(w));
        assertFalse(vault.isWithdrawAddress(w));
    }

    function test_Revert_Proposal_AddWithdrawAddressZero() public {
        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.ZeroAddress.selector);
        vault.proposeAddWithdrawAddress(address(0));
    }

    function test_Proposal_AddSigner() public {
        address s4 = makeAddr("signer4");
        _passProposal(DCAVaultStorage.ProposalType.AddSigner, abi.encode(s4));
        assertTrue(vault.isSigner(s4));
        assertEq(vault.getSigners().length, 4);
        assertEq(vault.getThreshold(), 2);
    }

    function test_Revert_Proposal_AddSignerThatIsOperator() public {
        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.RoleConflict.selector);
        vault.proposeAddSigner(operator);
    }

    function test_Revert_Proposal_AddExistingSigner() public {
        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.RoleConflict.selector);
        vault.proposeAddSigner(signer2);
    }

    function test_Proposal_RemoveSigner() public {
        _passProposal(DCAVaultStorage.ProposalType.RemoveSigner, abi.encode(signer3));
        assertFalse(vault.isSigner(signer3));
        assertEq(vault.getSigners().length, 2);
        assertEq(vault.getThreshold(), 1);
    }

    function test_Revert_Proposal_RemoveSignerBelowMin() public {
        _passProposal(DCAVaultStorage.ProposalType.RemoveSigner, abi.encode(signer3));
        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.TooFewSigners.selector);
        vault.proposeRemoveSigner(signer2);
    }

    function test_Proposal_AddRemoveOperator() public {
        address op2 = makeAddr("op2");
        _passProposal(DCAVaultStorage.ProposalType.AddOperator, abi.encode(op2));
        assertTrue(vault.isOperator(op2));
        _passProposal(DCAVaultStorage.ProposalType.RemoveOperator, abi.encode(op2));
        _passProposal(DCAVaultStorage.ProposalType.RemoveOperator, abi.encode(operator));
        assertFalse(vault.isOperator(op2));
        assertFalse(vault.isOperator(operator), "removing every operator is allowed");
    }

    function test_Revert_Proposal_AddOperatorThatIsSigner() public {
        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.RoleConflict.selector);
        vault.proposeAddOperator(signer3);
    }

    function test_Proposal_AddRemoveToken() public {
        MockERC20 t = new MockERC20("T", "T", 18);
        _passProposal(DCAVaultStorage.ProposalType.AddToken, abi.encode(address(t)));
        assertTrue(vault.allowedToken(address(t)));
        assertEq(vault.getAllowedTokens().length, 3);
        _passProposal(DCAVaultStorage.ProposalType.RemoveToken, abi.encode(address(t)));
        assertFalse(vault.allowedToken(address(t)));
        assertEq(vault.getAllowedTokens().length, 2);
    }

    function test_Revert_Proposal_AddStableAsToken() public {
        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.StableNotTradable.selector);
        vault.proposeAddToken(address(usdc));
    }

    function test_Revert_Proposal_RemoveStable() public {
        // The stable is not in the tradable list, so removing it fails at execution.
        vm.prank(signer1);
        uint256 id = vault.proposeRemoveToken(address(usdc));
        vm.prank(signer2);
        vm.expectRevert(DCAVaultStorage.NotFound.selector);
        vault.approve(id);
        assertEq(vault.stableToken(), address(usdc));
    }

    function test_Proposal_AddRemoveNativeToken() public {
        _passProposal(DCAVaultStorage.ProposalType.AddToken, abi.encode(address(0)));
        assertTrue(vault.allowedToken(address(0)));
        assertEq(vault.getAllowedTokens()[2], address(0));
        _passProposal(DCAVaultStorage.ProposalType.RemoveToken, abi.encode(address(0)));
        assertFalse(vault.allowedToken(address(0)));
    }

    function test_Proposal_SetAllowedFee() public {
        _passProposal(DCAVaultStorage.ProposalType.SetAllowedFee, abi.encode(uint24(100), true));
        assertTrue(vault.allowedFee(100));
        _passProposal(DCAVaultStorage.ProposalType.SetAllowedFee, abi.encode(uint24(500), false));
        assertFalse(vault.allowedFee(500));
        usdc.mint(address(vault), 1e6);
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.FeeNotAllowed.selector);
        vault.swapExactInputV3(address(usdc), address(weth), 500, 1e6, 1, block.timestamp);
    }

    function test_Revert_Proposal_SetAllowedFeeZero() public {
        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.InvalidFee.selector);
        vault.proposeSetAllowedFee(0, true);
    }

    function test_Proposal_SetAllowedTickSpacing() public {
        vm.prank(signer1);
        uint256 id = vault.proposeSetAllowedTickSpacing(200, true);
        assertFalse(vault.allowedTickSpacing(200), "needs threshold");
        vm.prank(signer2);
        vm.expectEmit(false, false, false, true, address(vault));
        emit DCAVaultStorage.TickSpacingAllowed(200, true);
        vault.approve(id);
        assertTrue(vault.allowedTickSpacing(200));

        _passProposal(DCAVaultStorage.ProposalType.SetAllowedTickSpacing, abi.encode(TS_LOW, false));
        assertFalse(vault.allowedTickSpacing(TS_LOW));
        usdc.mint(address(vault), 1e6);
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.TickSpacingNotAllowed.selector);
        vault.swapExactInputV4(address(usdc), address(weth), FEE_LOW, TS_LOW, 1e6, 1, block.timestamp);
    }

    function test_Revert_Proposal_SetAllowedTickSpacingOutOfRange() public {
        vm.startPrank(signer1);
        vm.expectRevert(DCAVaultStorage.InvalidTickSpacing.selector);
        vault.proposeSetAllowedTickSpacing(0, true);
        vm.expectRevert(DCAVaultStorage.InvalidTickSpacing.selector);
        vault.proposeSetAllowedTickSpacing(-1, true);
        vm.expectRevert(DCAVaultStorage.InvalidTickSpacing.selector);
        vault.proposeSetAllowedTickSpacing(int24(type(int16).max) + 1, true);
        vm.stopPrank();
    }

    function test_Revert_Proposal_SetAllowedTickSpacingNotSigner() public {
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.NotSigner.selector);
        vault.proposeSetAllowedTickSpacing(200, true);
    }

    function test_Proposal_ChangeMorphoVaultMigrates() public {
        _deposit(1000e6);
        usdc.mint(address(vault), 5e6); // idle USDC also moves into the new vault
        MockMorphoVault newVault = _newMorphoVault(usdc);

        vm.prank(signer1);
        uint256 id = vault.proposeChangeMorphoVault(address(newVault));
        vm.prank(signer2);
        vm.expectEmit(false, false, false, true, address(vault));
        emit DCAVaultStorage.MorphoVaultChanged(address(morpho), address(newVault), 1005e6);
        vault.approve(id);

        assertEq(vault.morphoVault(), address(newVault));
        assertEq(morpho.balanceOf(address(vault)), 0);
        assertEq(newVault.balanceOf(address(vault)), 1005e6);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(usdc.allowance(address(vault), address(newVault)), 0);
        _assertNoAllowances();
    }

    /// @dev Propose rejects the current vault early; execute re-checks for two pending proposals to the same vault.
    function test_Revert_Proposal_ChangeMorphoVaultSame() public {
        MockMorphoVault newVault = _newMorphoVault(usdc);
        vm.prank(signer1);
        uint256 a = vault.proposeChangeMorphoVault(address(newVault));
        vm.prank(signer3);
        uint256 b = vault.proposeChangeMorphoVault(address(newVault));
        vm.prank(signer2);
        vault.approve(a);
        vm.prank(signer2);
        vm.expectRevert(DCAVaultStorage.SameMorphoVault.selector);
        vault.approve(b);
    }

    // =================================================================== protocol address changes

    function test_Proposal_ChangeUniV3RouterSwapsUseNewRouter() public {
        MockSwapRouter newRouter = new MockSwapRouter();
        newRouter.setRate(address(usdc), address(weth), 5e8, 1);

        vm.prank(signer1);
        uint256 id = vault.proposeChangeUniV3Router(address(newRouter));
        assertEq(vault.uniV3Router(), address(router), "1 vote must not change the router");
        vm.prank(signer2);
        vm.expectEmit(false, false, false, true, address(vault));
        emit DCAVaultStorage.UniV3RouterChanged(address(router), address(newRouter));
        vault.approve(id);
        assertEq(vault.uniV3Router(), address(newRouter));

        usdc.mint(address(vault), 100e6);
        vm.prank(operator);
        vault.swapExactInputV3(address(usdc), address(weth), FEE_LOW, 100e6, 1, block.timestamp);
        assertEq(newRouter.lastRecipient(), address(vault));
        assertEq(router.lastRecipient(), address(0), "old router must not be used");
        assertEq(usdc.allowance(address(vault), address(newRouter)), 0);
        _assertNoAllowances();
    }

    function test_Proposal_ChangePermit2() public {
        address newPermit2 = makeAddr("newPermit2");
        vm.prank(signer1);
        uint256 id = vault.proposeChangePermit2(newPermit2);
        vm.prank(signer2);
        vm.expectEmit(false, false, false, true, address(vault));
        emit DCAVaultStorage.Permit2Changed(permit2, newPermit2);
        vault.approve(id);
        assertEq(vault.permit2(), newPermit2);
    }

    function test_Proposal_ChangeUniversalRouter() public {
        address newUr = makeAddr("newUniversalRouter");
        vm.prank(signer1);
        uint256 id = vault.proposeChangeUniversalRouter(newUr);
        vm.prank(signer2);
        vm.expectEmit(false, false, false, true, address(vault));
        emit DCAVaultStorage.UniversalRouterChanged(universalRouter, newUr);
        vault.approve(id);
        assertEq(vault.universalRouter(), newUr);
    }

    function test_Revert_Proposal_ChangeProtocolAddressZero() public {
        vm.startPrank(signer1);
        vm.expectRevert(DCAVaultStorage.ZeroAddress.selector);
        vault.proposeChangeUniV3Router(address(0));
        vm.expectRevert(DCAVaultStorage.ZeroAddress.selector);
        vault.proposeChangePermit2(address(0));
        vm.expectRevert(DCAVaultStorage.ZeroAddress.selector);
        vault.proposeChangeUniversalRouter(address(0));
        vm.stopPrank();
    }

    function test_Revert_Proposal_ChangeProtocolAddressSame() public {
        vm.startPrank(signer1);
        vm.expectRevert(DCAVaultStorage.SameAddress.selector);
        vault.proposeChangeUniV3Router(address(router));
        vm.expectRevert(DCAVaultStorage.SameAddress.selector);
        vault.proposeChangePermit2(permit2);
        vm.expectRevert(DCAVaultStorage.SameAddress.selector);
        vault.proposeChangeUniversalRouter(universalRouter);
        vm.expectRevert(DCAVaultStorage.SameMorphoVault.selector);
        vault.proposeChangeMorphoVault(address(morpho));
        vm.stopPrank();
    }

    /// @dev Two pending proposals for the same new router: the second one re-checks at execute time.
    function test_Revert_Proposal_ChangeUniV3RouterSameAtExecute() public {
        address newRouter = makeAddr("newRouter");
        vm.prank(signer1);
        uint256 a = vault.proposeChangeUniV3Router(newRouter);
        vm.prank(signer3);
        uint256 b = vault.proposeChangeUniV3Router(newRouter);
        vm.prank(signer2);
        vault.approve(a);
        vm.prank(signer2);
        vm.expectRevert(DCAVaultStorage.SameAddress.selector);
        vault.approve(b);
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
        _passProposal(DCAVaultStorage.ProposalType.WithdrawBatch, abi.encode(_addrs(address(usdc)), amounts, treasury));
        assertEq(usdc.balanceOf(treasury), 300e6);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.totalStable(), 710e6);
        _assertNoAllowances();
    }

    function test_WithdrawBatch_UsdcIdleOnlyDoesNotTouchMorpho() public {
        _deposit(1000e6);
        usdc.mint(address(vault), 50e6);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 40e6;
        _passProposal(DCAVaultStorage.ProposalType.WithdrawBatch, abi.encode(_addrs(address(usdc)), amounts, treasury));
        assertEq(morpho.balanceOf(address(vault)), 1000e6);
        assertEq(usdc.balanceOf(address(vault)), 10e6);
    }

    function test_WithdrawBatch_UsdcMaxRedeemsEverything() public {
        _deposit(1000e6);
        usdc.mint(address(vault), 10e6);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint256).max;
        _passProposal(DCAVaultStorage.ProposalType.WithdrawBatch, abi.encode(_addrs(address(usdc)), amounts, treasury));
        assertEq(usdc.balanceOf(treasury), 1010e6);
        assertEq(morpho.balanceOf(address(vault)), 0);
        assertEq(vault.totalStable(), 0);
    }

    function test_Revert_WithdrawBatch_ToNotWhitelisted() public {
        weth.mint(address(vault), 1 ether);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.WithdrawAddressNotAllowed.selector);
        vault.proposeWithdrawBatch(_addrs(address(weth)), amounts, attacker);
    }

    function test_Revert_WithdrawBatch_LengthMismatch() public {
        uint256[] memory amounts = new uint256[](2);
        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.BadArrayLength.selector);
        vault.proposeWithdrawBatch(_addrs(address(weth)), amounts, treasury);
    }

    function test_Revert_WithdrawBatch_Empty() public {
        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.BadArrayLength.selector);
        vault.proposeWithdrawBatch(new address[](0), new uint256[](0), treasury);
    }

    function test_Revert_WithdrawBatch_ZeroAmount() public {
        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.ZeroAmount.selector);
        vault.proposeWithdrawBatch(_addrs(address(weth)), new uint256[](1), treasury);
    }

    function test_Revert_WithdrawBatch_InsufficientBalance() public {
        weth.mint(address(vault), 1 ether);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 2 ether;
        vm.prank(signer1);
        uint256 id = vault.proposeWithdrawBatch(_addrs(address(weth)), amounts, treasury);
        vm.prank(signer2);
        vm.expectRevert(DCAVaultStorage.InsufficientBalance.selector);
        vault.approve(id);
    }

    function test_Revert_WithdrawBatch_AddressRemovedBeforeExecute() public {
        weth.mint(address(vault), 1 ether);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        vm.prank(signer1);
        uint256 id = vault.proposeWithdrawBatch(_addrs(address(weth)), amounts, treasury);
        _passProposal(DCAVaultStorage.ProposalType.RemoveWithdrawAddress, abi.encode(treasury));
        vm.prank(signer2);
        vm.expectRevert(DCAVaultStorage.WithdrawAddressNotAllowed.selector);
        vault.approve(id);
    }

    // =================================================================== pause / unpause

    function test_Pause_SingleSigner() public {
        vm.prank(signer3);
        vm.expectEmit(true, false, false, false, address(vault));
        emit DCAVaultStorage.Paused(signer3);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_Revert_Pause_NotSigner() public {
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.NotSigner.selector);
        vault.pause();
    }

    function test_Revert_Pause_AlreadyPaused() public {
        vm.prank(signer1);
        vault.pause();
        vm.prank(signer2);
        vm.expectRevert(DCAVaultStorage.IsPaused.selector);
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
        vm.expectRevert(DCAVaultStorage.NotPaused.selector);
        vault.approve(id);
    }

    function test_ProposalsWorkWhilePaused() public {
        weth.mint(address(vault), 1 ether);
        vm.prank(signer1);
        vault.pause();
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        _passProposal(DCAVaultStorage.ProposalType.WithdrawBatch, abi.encode(_addrs(address(weth)), amounts, treasury));
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
        assertEq(tokens.length, 2, "stable is reported separately, not in tokens");
        assertEq(tokens[0], address(weth));
        assertEq(bals[0], 1 ether);
        assertEq(bals[1], 5e7);
        assertEq(vault.totalStable(), 103e6);
    }

    function test_Revert_GetProposal_NotFound() public {
        vm.expectRevert(DCAVaultStorage.ProposalNotFound.selector);
        vault.getProposal(0);
    }

    // =================================================================== native ETH (address(0), V4 only)

    /// @dev Whitelists native ETH and sets mock V4 rates: 1 USDC -> 0.0005 ETH, 1 ETH -> 2000 USDC.
    function _enableNative() internal {
        _passProposal(DCAVaultStorage.ProposalType.AddToken, abi.encode(address(0)));
        v4Router.setRate(address(usdc), address(0), 5e8, 1);
        v4Router.setRate(address(0), address(usdc), 2e9, 1e18);
        vm.deal(address(v4Router), 100 ether);
    }

    function test_SwapExactInputV4_BuyNative() public {
        _enableNative();
        usdc.mint(address(vault), 100e6);
        vm.prank(operator);
        vm.expectEmit(true, true, false, true, address(vault));
        emit DCAVaultStorage.Swapped(address(usdc), address(0), FEE_LOW, 100e6, 0.05 ether, 4);
        uint256 out = vault.swapExactInputV4(address(usdc), address(0), FEE_LOW, TS_LOW, 100e6, 1, block.timestamp);
        assertEq(out, 0.05 ether);
        assertEq(address(vault).balance, 0.05 ether, "ETH stays idle in the vault");
        (address c0,,,,) = v4Router.lastKey();
        assertEq(c0, address(0), "native ETH is currency0");
        _assertNoAllowances();

        (,, address[] memory tokens, uint256[] memory bals) = vault.getBalances();
        assertEq(tokens[2], address(0));
        assertEq(bals[2], 0.05 ether);
    }

    function test_SwapExactInputV4_SellNativeSuppliesStableToMorpho() public {
        _enableNative();
        vm.deal(address(vault), 1 ether); // forced in (e.g. earlier buy); receive() would reject a plain send
        vm.prank(operator);
        uint256 out = vault.swapExactInputV4(address(0), address(usdc), FEE_LOW, TS_LOW, 1 ether, 1, block.timestamp);
        assertEq(out, 2000e6);
        assertEq(address(vault).balance, 0);
        assertEq(address(v4Router).balance, 101 ether, "exactly amountIn sent as msg.value");
        assertEq(vault.totalStable(), 2000e6);
        assertEq(usdc.balanceOf(address(vault)), 0, "sell proceeds supplied to Morpho");
        _assertNoAllowances();
    }

    function test_Revert_SwapExactInputV4_SellNativeInsufficientBalance() public {
        _enableNative();
        vm.deal(address(vault), 1 ether);
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.InsufficientBalance.selector);
        vault.swapExactInputV4(address(0), address(usdc), FEE_LOW, TS_LOW, 1 ether + 1, 1, block.timestamp);
    }

    function test_Revert_SwapExactInputV4_NativeNotWhitelisted() public {
        usdc.mint(address(vault), 100e6);
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.TokenNotAllowed.selector);
        vault.swapExactInputV4(address(usdc), address(0), FEE_LOW, TS_LOW, 100e6, 1, block.timestamp);
    }

    function test_Revert_SwapExactInputV3_Native() public {
        _enableNative();
        usdc.mint(address(vault), 100e6);
        vm.deal(address(vault), 1 ether);
        vm.startPrank(operator);
        vm.expectRevert(DCAVaultStorage.NativeNotSupported.selector);
        vault.swapExactInputV3(address(usdc), address(0), FEE_LOW, 100e6, 1, block.timestamp);
        vm.expectRevert(DCAVaultStorage.NativeNotSupported.selector);
        vault.swapExactInputV3(address(0), address(usdc), FEE_LOW, 1 ether, 1, block.timestamp);
        vm.stopPrank();
    }

    function test_Revert_WithdrawAndSwapV3_Native() public {
        _enableNative();
        _deposit(100e6);
        vm.prank(operator);
        vm.expectRevert(DCAVaultStorage.NativeNotSupported.selector);
        vault.withdrawAndSwapV3(address(0), FEE_LOW, 100e6, 1, block.timestamp);
    }

    function test_WithdrawBatch_Native() public {
        _enableNative();
        vm.deal(address(vault), 2 ether);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0.5 ether;
        amounts[1] = type(uint256).max;
        address[] memory tokens = _addrs(address(0), address(0));
        _passProposal(DCAVaultStorage.ProposalType.WithdrawBatch, abi.encode(tokens, amounts, treasury));
        assertEq(treasury.balance, 2 ether);
        assertEq(address(vault).balance, 0);
    }

    function test_Revert_WithdrawBatch_NativeNotWhitelisted() public {
        vm.deal(address(vault), 1 ether);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.TokenNotAllowed.selector);
        vault.proposeWithdrawBatch(_addrs(address(0)), amounts, treasury);
    }

    function test_Revert_WithdrawBatch_NativeReceiverRejects() public {
        _enableNative();
        vm.deal(address(vault), 1 ether);
        // A contract without receive() as withdraw address: the ETH transfer fails -> whole batch reverts.
        address noReceive = address(new MockERC20("N", "N", 18));
        _passProposal(DCAVaultStorage.ProposalType.AddWithdrawAddress, abi.encode(noReceive));
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        vm.prank(signer1);
        uint256 id = vault.proposeWithdrawBatch(_addrs(address(0)), amounts, noReceive);
        vm.prank(signer2);
        vm.expectRevert(DCAVaultStorage.NativeTransferFailed.selector);
        vault.approve(id);
        assertEq(address(vault).balance, 1 ether);
    }

    // =================================================================== ChangeStableToken

    function test_Proposal_ChangeStableTokenSweepsOldStable() public {
        _deposit(1000e6);
        usdc.mint(address(vault), 5e6); // idle old stable
        MockERC20 newStable = new MockERC20("New USD", "NUSD", 18);
        MockMorphoVault newVault = _newMorphoVault(newStable);

        vm.prank(signer1);
        uint256 id = vault.proposeChangeStableToken(address(newStable), address(newVault), treasury);
        vm.prank(signer2);
        vm.expectEmit(false, false, false, true, address(vault));
        emit DCAVaultStorage.StableTokenChanged(
            address(usdc), address(newStable), address(morpho), address(newVault), 1005e6
        );
        vault.approve(id);

        assertEq(usdc.balanceOf(treasury), 1005e6, "every unit of old stable swept");
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(morpho.balanceOf(address(vault)), 0);
        assertEq(vault.stableToken(), address(newStable));
        assertEq(vault.morphoVault(), address(newVault));

        // The new stable now drives deposits, swaps and Morpho.
        newStable.mint(user, 50e18);
        vm.startPrank(user);
        newStable.approve(address(vault), 50e18);
        vault.depositAndSupply(50e18);
        vm.stopPrank();
        assertEq(vault.totalStable(), 50e18);
        assertEq(newStable.allowance(address(vault), address(newVault)), 0);

        // The old stable is now just an unlisted token.
        usdc.mint(address(vault), 1e6);
        vm.prank(signer1);
        vm.expectRevert(DCAVaultStorage.TokenNotAllowed.selector);
        vault.proposeWithdrawBatch(_addrs(address(usdc)), _amounts(1e6), treasury);
    }

    function test_Proposal_ChangeStableTokenCannotBeGriefedByDust() public {
        _deposit(1000e6);
        MockERC20 newStable = new MockERC20("New USD", "NUSD", 18);
        MockMorphoVault newVault = _newMorphoVault(newStable);
        vm.prank(signer1);
        uint256 id = vault.proposeChangeStableToken(address(newStable), address(newVault), treasury);
        // Someone donates / deposits old stable between propose and execute: it is simply swept too.
        usdc.mint(address(vault), 1);
        _deposit(1);
        vm.prank(signer2);
        vault.approve(id);
        assertEq(usdc.balanceOf(treasury), 1000e6 + 2);
        assertEq(vault.stableToken(), address(newStable));
    }

    function test_Revert_Proposal_ChangeStableTokenInvalid() public {
        MockERC20 newStable = new MockERC20("New USD", "NUSD", 18);
        MockMorphoVault newVault = _newMorphoVault(newStable);
        vm.startPrank(signer1);
        vm.expectRevert(DCAVaultStorage.ZeroAddress.selector);
        vault.proposeChangeStableToken(address(0), address(newVault), treasury);
        vm.expectRevert(DCAVaultStorage.ZeroAddress.selector);
        vault.proposeChangeStableToken(address(newStable), address(0), treasury);
        vm.expectRevert(DCAVaultStorage.SameAddress.selector);
        vault.proposeChangeStableToken(address(usdc), address(newVault), treasury);
        vm.expectRevert(DCAVaultStorage.SameMorphoVault.selector);
        vault.proposeChangeStableToken(address(newStable), address(morpho), treasury);
        vm.expectRevert(DCAVaultStorage.StableNotTradable.selector);
        vault.proposeChangeStableToken(address(weth), address(newVault), treasury);
        vm.expectRevert(DCAVaultStorage.WithdrawAddressNotAllowed.selector);
        vault.proposeChangeStableToken(address(newStable), address(newVault), attacker);
        vm.stopPrank();
    }

    function test_Revert_Proposal_ChangeStableTokenWithdrawAddressRemovedBeforeExecute() public {
        MockERC20 newStable = new MockERC20("New USD", "NUSD", 18);
        MockMorphoVault newVault = _newMorphoVault(newStable);
        vm.prank(signer1);
        uint256 id = vault.proposeChangeStableToken(address(newStable), address(newVault), treasury);
        _passProposal(DCAVaultStorage.ProposalType.RemoveWithdrawAddress, abi.encode(treasury));
        vm.prank(signer2);
        vm.expectRevert(DCAVaultStorage.WithdrawAddressNotAllowed.selector);
        vault.approve(id);
        assertEq(vault.stableToken(), address(usdc));
    }

    function _amounts(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }
}
