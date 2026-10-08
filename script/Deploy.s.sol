// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {DCAVault} from "../src/DCAVault.sol";

/// @notice Deploys DCAVault on Base. All addresses come from env (see .env.example) — nothing is hardcoded.
/// @dev forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL --broadcast --verify
///      Dry-run first without --broadcast and read the printed config.
contract Deploy is Script {
    function run() external returns (DCAVault vault) {
        require(block.chainid == 8453, "Deploy: not Base mainnet");

        address stableToken = vm.envAddress("STABLE_TOKEN");
        address router = vm.envAddress("UNI_V3_ROUTER");
        address permit2 = vm.envAddress("PERMIT2");
        address universalRouter = vm.envAddress("UNIVERSAL_ROUTER");
        address morphoVault = vm.envAddress("MORPHO_VAULT");

        address[] memory signers = vm.envAddress("SIGNERS", ",");
        address[] memory operators = _envAddressesOrEmpty("OPERATORS");
        address[] memory withdrawAddresses = _envAddressesOrEmpty("WITHDRAW_ADDRESSES");

        // Tradable tokens only (the stable is passed separately). address(0) = native ETH (V4 only).
        address[] memory tokens = vm.envAddress("TOKENS", ",");

        uint256[] memory rawFees = vm.envUint("FEES", ",");
        uint24[] memory fees = new uint24[](rawFees.length);
        for (uint256 i; i < rawFees.length; ++i) {
            require(rawFees[i] > 0 && rawFees[i] <= type(uint24).max, "Deploy: bad fee");
            fees[i] = uint24(rawFees[i]);
        }

        int256[] memory rawTickSpacings = vm.envInt("TICK_SPACINGS", ",");
        int24[] memory tickSpacings = new int24[](rawTickSpacings.length);
        for (uint256 i; i < rawTickSpacings.length; ++i) {
            require(rawTickSpacings[i] >= 1 && rawTickSpacings[i] <= type(int16).max, "Deploy: bad tick spacing");
            tickSpacings[i] = int24(rawTickSpacings[i]);
        }

        // Pre-flight: every protocol/token address must have code, and Morpho must be a vault for the stable.
        _requireCode(stableToken, "STABLE_TOKEN");
        for (uint256 i; i < tokens.length; ++i) {
            require(tokens[i] != stableToken, "Deploy: STABLE_TOKEN must not be in TOKENS");
            if (tokens[i] != address(0)) _requireCode(tokens[i], "TOKENS");
        }
        _requireCode(router, "UNI_V3_ROUTER");
        _requireCode(permit2, "PERMIT2");
        _requireCode(universalRouter, "UNIVERSAL_ROUTER");
        _requireCode(morphoVault, "MORPHO_VAULT");
        require(IERC4626(morphoVault).asset() == stableToken, "Deploy: MORPHO_VAULT asset != STABLE_TOKEN");
        require(withdrawAddresses.length > 0, "Deploy: set WITHDRAW_ADDRESSES");

        _print(stableToken, router, permit2, universalRouter, morphoVault, signers, operators, withdrawAddresses, fees);
        for (uint256 i; i < tokens.length; ++i) {
            console2.log("token    ", tokens[i]);
        }
        for (uint256 i; i < tickSpacings.length; ++i) {
            console2.log("tickSpacing", int256(tickSpacings[i]));
        }

        vm.startBroadcast(vm.envUint("PRIVATE_KEY_DEPLOYER"));
        vault = new DCAVault(
            stableToken,
            router,
            permit2,
            universalRouter,
            morphoVault,
            signers,
            operators,
            withdrawAddresses,
            tokens,
            fees,
            tickSpacings
        );
        vm.stopBroadcast();

        console2.log("DCAVault deployed at:", address(vault));
        console2.log("threshold:", vault.getThreshold());
    }

    function _envAddressesOrEmpty(string memory key) internal view returns (address[] memory) {
        string memory raw = vm.envOr(key, string(""));
        if (bytes(raw).length == 0) return new address[](0);
        return vm.envAddress(key, ",");
    }

    function _requireCode(address a, string memory name) internal view {
        require(a.code.length > 0, string.concat("Deploy: no code at ", name));
    }

    function _print(
        address stableToken,
        address router,
        address permit2,
        address universalRouter,
        address morphoVault,
        address[] memory signers,
        address[] memory operators,
        address[] memory withdrawAddresses,
        uint24[] memory fees
    ) internal pure {
        console2.log("STABLE_TOKEN    ", stableToken);
        console2.log("UNI_V3_ROUTER   ", router);
        console2.log("PERMIT2         ", permit2);
        console2.log("UNIVERSAL_ROUTER", universalRouter);
        console2.log("MORPHO_VAULT    ", morphoVault);
        for (uint256 i; i < signers.length; ++i) {
            console2.log("signer   ", signers[i]);
        }
        for (uint256 i; i < operators.length; ++i) {
            console2.log("operator ", operators[i]);
        }
        for (uint256 i; i < withdrawAddresses.length; ++i) {
            console2.log("withdraw ", withdrawAddresses[i]);
        }
        for (uint256 i; i < fees.length; ++i) {
            console2.log("fee      ", fees[i]);
        }
    }
}
