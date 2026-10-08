// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {DCAVault} from "../src/DCAVault.sol";
import {DCAVaultStorage} from "../src/vault/DCAVaultStorage.sol";

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

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

        DCAVaultStorage.PoolConfig[] memory pools = _envPools();

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

        // Every V3 pool entry must already exist: an allowed-but-missing pool can be created by anyone.
        // V4 pools have no factory to query here — check them on a fork / the Uniswap UI before deploying.
        IUniswapV3Factory factory = IUniswapV3Factory(vm.envAddress("UNI_V3_FACTORY"));
        for (uint256 i; i < pools.length; ++i) {
            if (pools[i].tickSpacing == 0) {
                address pool = factory.getPool(stableToken, pools[i].token, pools[i].fee);
                require(pool != address(0), "Deploy: V3 pool in POOL_* does not exist");
            }
        }

        _print(stableToken, router, permit2, universalRouter, morphoVault, signers, operators, withdrawAddresses);
        for (uint256 i; i < tokens.length; ++i) {
            console2.log("token    ", tokens[i]);
        }
        for (uint256 i; i < pools.length; ++i) {
            console2.log("pool     ", pools[i].token);
            console2.log("  fee    ", uint256(pools[i].fee));
            console2.log("  spacing (0 = V3)", int256(pools[i].tickSpacing));
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
            pools
        );
        vm.stopBroadcast();

        console2.log("DCAVault deployed at:", address(vault));
        console2.log("threshold:", vault.getThreshold());
    }

    /// @dev Reads POOL_TOKENS / POOL_FEES / POOL_TICK_SPACINGS (parallel lists, one entry per pool).
    function _envPools() internal view returns (DCAVaultStorage.PoolConfig[] memory pools) {
        address[] memory poolTokens = vm.envAddress("POOL_TOKENS", ",");
        uint256[] memory poolFees = vm.envUint("POOL_FEES", ",");
        int256[] memory poolSpacings = vm.envInt("POOL_TICK_SPACINGS", ",");
        require(
            poolTokens.length == poolFees.length && poolTokens.length == poolSpacings.length,
            "Deploy: POOL_* lists differ in length"
        );
        pools = new DCAVaultStorage.PoolConfig[](poolTokens.length);
        for (uint256 i; i < poolTokens.length; ++i) {
            require(poolFees[i] > 0 && poolFees[i] <= 1_000_000, "Deploy: bad pool fee");
            require(poolSpacings[i] >= 0 && poolSpacings[i] <= type(int16).max, "Deploy: bad pool tick spacing");
            pools[i] = DCAVaultStorage.PoolConfig(poolTokens[i], uint24(poolFees[i]), int24(poolSpacings[i]));
        }
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
        address[] memory withdrawAddresses
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
    }
}
