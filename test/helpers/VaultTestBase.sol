// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DCAVault} from "../../src/DCAVault.sol";
import {DCAVaultStorage} from "../../src/vault/DCAVaultStorage.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockMorphoVault} from "../mocks/MockMorphoVault.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";

/// @dev Deploys the vault against mocks: 3 signers (threshold 2), 1 operator, 1 withdraw address.
abstract contract VaultTestBase is Test {
    DCAVault internal vault;
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockERC20 internal cbbtc;
    MockMorphoVault internal morpho;
    MockSwapRouter internal router;

    address internal signer1 = makeAddr("signer1");
    address internal signer2 = makeAddr("signer2");
    address internal signer3 = makeAddr("signer3");
    address internal operator = makeAddr("operator");
    address internal treasury = makeAddr("treasury");
    address internal user = makeAddr("user");
    address internal attacker = makeAddr("attacker");
    address internal permit2 = makeAddr("permit2");
    address internal universalRouter = makeAddr("universalRouter");

    uint24 internal constant FEE_LOW = 500;
    uint24 internal constant FEE_MED = 3000;

    function setUp() public virtual {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        cbbtc = new MockERC20("Coinbase BTC", "cbBTC", 8);
        morpho = new MockMorphoVault(usdc);
        router = new MockSwapRouter();

        // 1 USDC (1e6) -> 0.0005 WETH (5e14)  => num/den = 5e14 / 1e6 = 5e8
        router.setRate(address(usdc), address(weth), 5e8, 1);
        // 1 WETH (1e18) -> 2000 USDC (2000e6) => 2e9 / 1e18
        router.setRate(address(weth), address(usdc), 2e9, 1e18);
        // 1 USDC (1e6) -> 0.00001 cbBTC (1e3)
        router.setRate(address(usdc), address(cbbtc), 1, 1e3);
        // 1 cbBTC (1e8) -> 100_000 USDC (1e11)
        router.setRate(address(cbbtc), address(usdc), 1e3, 1);
        // 1 WETH -> 0.02 cbBTC (2e6)
        router.setRate(address(weth), address(cbbtc), 2e6, 1e18);

        vault = _deploy(_addrs(signer1, signer2, signer3), _addrs(operator), _addrs(treasury));
    }

    // ---------------------------------------------------------------- helpers

    function _deploy(address[] memory s, address[] memory o, address[] memory w) internal returns (DCAVault) {
        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc);
        tokens[1] = address(weth);
        tokens[2] = address(cbbtc);
        uint24[] memory fees = new uint24[](2);
        fees[0] = FEE_LOW;
        fees[1] = FEE_MED;
        return
            new DCAVault(
                address(usdc), address(router), permit2, universalRouter, address(morpho), s, o, w, tokens, fees
            );
    }

    function _addrs(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _addrs(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }

    function _addrs(address a, address b, address c) internal pure returns (address[] memory r) {
        r = new address[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    function _deposit(uint256 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.depositAndSupply(amount);
        vm.stopPrank();
    }

    /// @dev Proposes from signer1 and approves from signer2 => executes with threshold 2.
    function _passProposal(DCAVaultStorage.ProposalType t, bytes memory data) internal returns (uint256 id) {
        vm.prank(signer1);
        id = vault.propose(t, data);
        vm.prank(signer2);
        vault.approve(id);
    }

    function _assertNoAllowances() internal view {
        assertEq(usdc.allowance(address(vault), address(router)), 0, "usdc->router");
        assertEq(weth.allowance(address(vault), address(router)), 0, "weth->router");
        assertEq(cbbtc.allowance(address(vault), address(router)), 0, "cbbtc->router");
        assertEq(usdc.allowance(address(vault), address(morpho)), 0, "usdc->morpho");
        assertEq(usdc.allowance(address(vault), permit2), 0, "usdc->permit2");
    }
}
