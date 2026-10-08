// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUniversalRouter} from "../../src/interfaces/IUniversalRouter.sol";
import {IV4Router} from "../../src/interfaces/IV4Router.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockPermit2} from "./MockPermit2.sol";

/// @dev Fake UniversalRouter that only understands V4_SWAP(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL).
///      Decodes exactly what the vault built, pulls tokenIn through Permit2 and mints `amountIn * num / den`
///      of tokenOut to msg.sender (like TAKE_ALL). Native ETH (address(0)): tokenIn must arrive as msg.value,
///      tokenOut is paid in ETH from this contract's balance (fund it with vm.deal).
///      Test-only knobs simulate a malicious router.
contract MockUniversalRouter is IUniversalRouter {
    MockPermit2 public immutable permit2;

    mapping(address => mapping(address => uint256)) public rateNum;
    mapping(address => mapping(address => uint256)) public rateDen;

    /// @dev If set, tries to pull more than amountIn (must fail: Permit2 allowance is exact).
    bool public pullExtra;
    /// @dev If set, delivers half the output and skips the TAKE_ALL min check.
    bool public deliverHalf;
    /// @dev If set, also pushes 1 wei of native ETH to the caller (must be rejected unless buying ETH).
    bool public pushNative;

    // Last decoded call, for assertions.
    IV4Router.PoolKey public lastKey;
    bool public lastZeroForOne;
    bytes public lastActions;

    constructor(MockPermit2 _permit2) {
        permit2 = _permit2;
    }

    function setRate(address tokenIn, address tokenOut, uint256 num, uint256 den) external {
        rateNum[tokenIn][tokenOut] = num;
        rateDen[tokenIn][tokenOut] = den;
    }

    function setPullExtra(bool v) external {
        pullExtra = v;
    }

    function setDeliverHalf(bool v) external {
        deliverHalf = v;
    }

    function setPushNative(bool v) external {
        pushNative = v;
    }

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable {
        require(block.timestamp <= deadline, "TransactionDeadlinePassed");
        require(commands.length == 1 && commands[0] == 0x10 && inputs.length == 1, "only V4_SWAP");
        (bytes memory actions, bytes[] memory params) = abi.decode(inputs[0], (bytes, bytes[]));
        require(keccak256(actions) == keccak256(hex"060c0f") && params.length == 3, "bad actions");
        lastActions = actions;

        IV4Router.ExactInputSingleParams memory p = abi.decode(params[0], (IV4Router.ExactInputSingleParams));
        (address settleCurrency, uint256 maxIn) = abi.decode(params[1], (address, uint256));
        (address takeCurrency, uint256 minOut) = abi.decode(params[2], (address, uint256));
        lastKey = p.poolKey;
        lastZeroForOne = p.zeroForOne;

        require(p.poolKey.currency0 < p.poolKey.currency1, "unsorted key");
        address tokenIn = p.zeroForOne ? p.poolKey.currency0 : p.poolKey.currency1;
        address tokenOut = p.zeroForOne ? p.poolKey.currency1 : p.poolKey.currency0;
        require(settleCurrency == tokenIn && takeCurrency == tokenOut, "currency mismatch");
        require(maxIn == p.amountIn, "maxIn");

        if (tokenIn == address(0)) {
            require(msg.value == p.amountIn, "native: msg.value != amountIn");
        } else {
            require(msg.value == 0, "unexpected msg.value");
            uint256 pull = pullExtra ? uint256(p.amountIn) + 1 : p.amountIn;
            permit2.transferFrom(msg.sender, address(this), uint160(pull), tokenIn);
        }

        if (pushNative) _pay(address(0), msg.sender, 1);

        uint256 out = uint256(p.amountIn) * rateNum[tokenIn][tokenOut] / rateDen[tokenIn][tokenOut];
        if (deliverHalf) {
            _pay(tokenOut, msg.sender, out / 2);
            return;
        }
        require(out >= p.amountOutMinimum && out >= minOut, "V4TooLittleReceived");
        _pay(tokenOut, msg.sender, out);
    }

    function _pay(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "native take failed");
        } else {
            MockERC20(token).mint(to, amount);
        }
    }
}
