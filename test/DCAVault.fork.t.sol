// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {DCAVault} from "../src/DCAVault.sol";

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

/// @notice Base mainnet fork tests against the real USDC / WETH / cbBTC, SwapRouter02 and MetaMorpho.
/// @dev Run: `forge test --fork-url $BASE_RPC_URL --match-path test/DCAVault.fork.t.sol -vvv`
///      (or just set BASE_RPC_URL). Skipped when no Base RPC is available.
contract DCAVaultForkTest is Test {
    // Verified on-chain 2026-10-08 (DCA_VAULT_SPEC.md section 3).
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address constant STEAKHOUSE_USDC = 0xbeeff7aE5E00Aae3Db302e4B0d8C883810a58100;
    /// @dev Second MetaMorpho USDC vault, only used as the ChangeMorphoVault target in tests.
    address constant GAUNTLET_USDC_PRIME = 0xeE8F4eC5672F09119b96Ab6fB59C27E1b7e44b61;

    DCAVault vault;
    address signer1 = makeAddr("signer1");
    address signer2 = makeAddr("signer2");
    address signer3 = makeAddr("signer3");
    address operator = makeAddr("operator");
    address treasury = makeAddr("treasury");
    address user = makeAddr("user");

    function setUp() public {
        if (block.chainid != 8453) {
            string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
            if (bytes(rpc).length == 0) {
                vm.skip(true);
                return;
            }
            vm.createSelectFork(rpc);
        }

        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;
        address[] memory operators = new address[](1);
        operators[0] = operator;
        address[] memory withdraws = new address[](1);
        withdraws[0] = treasury;
        address[] memory tokens = new address[](3);
        tokens[0] = USDC;
        tokens[1] = WETH;
        tokens[2] = CBBTC;
        uint24[] memory fees = new uint24[](2);
        fees[0] = 500;
        fees[1] = 3000;

        vault = new DCAVault(
            USDC, ROUTER, PERMIT2, UNIVERSAL_ROUTER, STEAKHOUSE_USDC, signers, operators, withdraws, tokens, fees
        );

        deal(USDC, user, 10_000e6);
        vm.startPrank(user);
        IERC20(USDC).approve(address(vault), 10_000e6);
        vault.depositAndSupply(10_000e6);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ deposit

    function test_Fork_DepositAndSupply_GoesToMorpho() public view {
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0);
        assertGt(IERC4626(STEAKHOUSE_USDC).balanceOf(address(vault)), 0);
        assertApproxEqAbs(vault.totalUsdc(), 10_000e6, 2); // ERC-4626 rounding
        _assertNoAllowances(STEAKHOUSE_USDC);
    }

    // ------------------------------------------------------------------ buys

    function test_Fork_WithdrawAndSwapV3_UsdcToWeth() public {
        uint256 minOut = _quote(USDC, WETH, 500, 1_000e6) * 995 / 1000; // 0.5% slippage like the bot
        vm.prank(operator);
        uint256 out = vault.withdrawAndSwapV3(WETH, 500, 1_000e6, minOut, block.timestamp + 60);
        assertGe(out, minOut);
        assertEq(IERC20(WETH).balanceOf(address(vault)), out);
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0);
        assertApproxEqAbs(vault.totalUsdc(), 9_000e6, 2);
        _assertNoAllowances(STEAKHOUSE_USDC);
    }

    function test_Fork_WithdrawAndSwapV3_UsdcToCbbtcDirect() public {
        uint256 minOut = _quote(USDC, CBBTC, 500, 1_000e6) * 99 / 100;
        vm.prank(operator);
        uint256 out = vault.withdrawAndSwapV3(CBBTC, 500, 1_000e6, minOut, block.timestamp + 60);
        assertGt(out, 0);
        assertEq(IERC20(CBBTC).balanceOf(address(vault)), out);
        _assertNoAllowances(STEAKHOUSE_USDC);
    }

    function test_Fork_SwapExactInputV3_WethToCbbtc3000() public {
        vm.prank(operator);
        uint256 weth = vault.withdrawAndSwapV3(WETH, 500, 2_000e6, 1, block.timestamp);
        vm.prank(operator);
        uint256 out = vault.swapExactInputV3(WETH, CBBTC, 3000, weth, 1, block.timestamp);
        assertGt(out, 0);
        assertEq(IERC20(WETH).balanceOf(address(vault)), 0);
        assertEq(IERC20(CBBTC).balanceOf(address(vault)), out);
        _assertNoAllowances(STEAKHOUSE_USDC);
    }

    function test_Fork_Revert_SlippageTooHigh() public {
        uint256 quoted = _quote(USDC, WETH, 500, 1_000e6);
        vm.prank(operator);
        vm.expectRevert(bytes("Too little received"));
        vault.withdrawAndSwapV3(WETH, 500, 1_000e6, quoted * 2, block.timestamp);
        assertApproxEqAbs(vault.totalUsdc(), 10_000e6, 2, "USDC stays in Morpho on failure");
    }

    // ------------------------------------------------------------------ sell -> Morpho

    function test_Fork_SellToUsdcAutoDepositsToMorpho() public {
        vm.prank(operator);
        uint256 weth = vault.withdrawAndSwapV3(WETH, 500, 1_000e6, 1, block.timestamp);
        uint256 sharesBefore = IERC4626(STEAKHOUSE_USDC).balanceOf(address(vault));

        vm.prank(operator);
        uint256 usdcOut = vault.swapExactInputV3(WETH, USDC, 500, weth, 1, block.timestamp);
        assertGt(usdcOut, 990e6); // round trip loses only fees + spread
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0, "proceeds must not sit idle");
        assertGt(IERC4626(STEAKHOUSE_USDC).balanceOf(address(vault)), sharesBefore);
        _assertNoAllowances(STEAKHOUSE_USDC);
    }

    // ------------------------------------------------------------------ morpho ops

    function test_Fork_MorphoWithdrawThenDeposit() public {
        vm.prank(operator);
        vault.morphoWithdraw(500e6);
        assertEq(IERC20(USDC).balanceOf(address(vault)), 500e6);
        vm.prank(operator);
        vault.morphoDeposit(500e6);
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0);
        assertApproxEqAbs(vault.totalUsdc(), 10_000e6, 3);
        _assertNoAllowances(STEAKHOUSE_USDC);
    }

    // ------------------------------------------------------------------ batch withdraw

    function test_Fork_WithdrawBatch_UsdcPartialAndWethMax() public {
        vm.prank(operator);
        uint256 weth = vault.withdrawAndSwapV3(WETH, 500, 1_000e6, 1, block.timestamp);

        address[] memory tokens = new address[](2);
        tokens[0] = USDC;
        tokens[1] = WETH;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 2_000e6;
        amounts[1] = type(uint256).max;
        vm.prank(signer1);
        uint256 id = vault.proposeWithdrawBatch(tokens, amounts, treasury);
        vm.prank(signer2);
        vault.approve(id);

        assertEq(IERC20(USDC).balanceOf(treasury), 2_000e6);
        assertEq(IERC20(WETH).balanceOf(treasury), weth);
        assertApproxEqAbs(vault.totalUsdc(), 7_000e6, 3);
    }

    function test_Fork_WithdrawBatch_UsdcMaxRedeemsAll() public {
        address[] memory tokens = new address[](1);
        tokens[0] = USDC;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint256).max;
        vm.prank(signer1);
        uint256 id = vault.proposeWithdrawBatch(tokens, amounts, treasury);
        vm.prank(signer3);
        vault.approve(id);

        assertEq(IERC4626(STEAKHOUSE_USDC).balanceOf(address(vault)), 0);
        assertApproxEqAbs(IERC20(USDC).balanceOf(treasury), 10_000e6, 2);
        assertEq(vault.totalUsdc(), 0);
    }

    // ------------------------------------------------------------------ change vault

    function test_Fork_ChangeMorphoVault_Migrates() public {
        vm.prank(signer1);
        uint256 id = vault.proposeChangeMorphoVault(GAUNTLET_USDC_PRIME);
        vm.prank(signer2);
        vault.approve(id);

        assertEq(vault.morphoVault(), GAUNTLET_USDC_PRIME);
        assertEq(IERC4626(STEAKHOUSE_USDC).balanceOf(address(vault)), 0);
        assertGt(IERC4626(GAUNTLET_USDC_PRIME).balanceOf(address(vault)), 0);
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0);
        assertApproxEqAbs(vault.totalUsdc(), 10_000e6, 3);
        _assertNoAllowances(STEAKHOUSE_USDC);
        _assertNoAllowances(GAUNTLET_USDC_PRIME);

        // operator flows keep working against the new vault
        vm.prank(operator);
        vault.withdrawAndSwapV3(WETH, 500, 100e6, 1, block.timestamp);
        assertGt(IERC20(WETH).balanceOf(address(vault)), 0);
    }

    // ------------------------------------------------------------------ helpers

    function _quote(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn) internal returns (uint256 out) {
        (out,,,) = IQuoterV2(QUOTER)
            .quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, fee: fee, sqrtPriceLimitX96: 0
                })
            );
    }

    function _assertNoAllowances(address morpho) internal view {
        address[3] memory toks = [USDC, WETH, CBBTC];
        for (uint256 i; i < 3; ++i) {
            assertEq(IERC20(toks[i]).allowance(address(vault), ROUTER), 0, "router allowance");
            assertEq(IERC20(toks[i]).allowance(address(vault), PERMIT2), 0, "permit2 allowance");
        }
        assertEq(IERC20(USDC).allowance(address(vault), morpho), 0, "morpho allowance");
    }
}
