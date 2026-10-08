# DCA Vault — Spec thiết kế (Base chain)

> File này là spec cho Claude Code. **Đọc hết trước khi code.** Mọi điểm đánh dấu `⚠️ CẦN XÁC NHẬN` phải hỏi lại chủ dự án trước khi implement.

---

## 1. Mục tiêu

Xây một smart contract vault trên **Base** để DCA **cbBTC** và **WETH / ETH** liên tục trong ~3 năm:

- **Một token stable duy nhất** (`stableToken`, hiện là USDC) — tách riêng khỏi danh sách token mua bán (chốt 2026-10-08).
- Stable nhàn rỗi **luôn** nằm trên **MetaMorpho Vault** (ERC-4626) để lấy yield. **Chỉ stable** được đưa lên Morpho.
- Khi bot off-chain thấy đủ điều kiện → rút **đúng số stable cần** từ Morpho → swap trên Uniswap.
- Token mua bán (`allowedToken`: cbBTC, WETH, tùy chọn ETH native) sau khi mua **nằm yên trong contract**, không staking, không đưa đi đâu (APR quá thấp, không đáng).
- Không ai (kể cả operator bị hack) có thể chuyển token ra ngoài, trừ khi multisig signers đồng ý và chỉ về địa chỉ đã whitelist.

Thay thế cho mô hình EOA hiện tại (approve unlimited cho Uniswap V3 Router, Permit2, Morpho Bundler → rủi ro lộ private key).

---

## 2. Tech stack

- **Ngôn ngữ:** Solidity `^0.8.24`
- **Framework:** Foundry (forge, cast, anvil)
- **Thư viện:** OpenZeppelin Contracts v5 (`SafeERC20`, `ReentrancyGuard`, `IERC4626`)
- **Chain:** Base mainnet (chainId `8453`), test trên fork Base mainnet bằng `anvil --fork-url`
- **Không dùng proxy/upgradeable.** Code contract immutable, mọi thay đổi cấu hình (kể cả địa chỉ protocol: Morpho, Uniswap V3 router, Permit2, UniversalRouter, token whitelist) qua multisig proposal. `stableToken` đổi được qua proposal `ChangeStableToken`, proposal này tự rút sạch stable cũ trước khi đổi (chốt 2026-10-08).

---

## 3. Địa chỉ trên Base

> ⚠️ Claude Code phải **verify lại từng địa chỉ trên basescan.org** trước khi đưa vào deploy script. Không hardcode trong contract — truyền qua constructor.

| Thành phần | Địa chỉ | Ghi chú |
|---|---|---|
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | 6 decimals |
| WETH | `0x4200000000000000000000000000000000000006` | 18 decimals |
| cbBTC | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` | 8 decimals |
| Uniswap V3 SwapRouter02 | `0x2626664c2603336E57B271c5C0b26F421741e481` | Router chính |
| Uniswap V3 QuoterV2 | `0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a` | Bot dùng off-chain để tính minOut |
| Uniswap V3 Factory | `0x33128a8fC17869897dcE68Ed026d694621f6FDfD` | Dùng trong test để lấy pool |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | Cho V4 |
| Uniswap UniversalRouter (V4) | `0x6ff5693b99212da76ad316178a184ab56d299b43` | ⚠️ Verify trên docs.uniswap.org/contracts/v4/deployments |
| Morpho Vault USDC | `0xbeeff7aE5E00Aae3Db302e4B0d8C883810a58100` | Steakhouse High Yield USDC — là **Morpho Vault V2** |

### Lưu ý kỹ thuật quan trọng

- **SwapRouter02 trên Base KHÔNG có field `deadline`** trong `ExactInputSingleParams` (khác SwapRouter V1 trên Ethereum). Struct đúng:
  ```solidity
  struct ExactInputSingleParams {
      address tokenIn;
      address tokenOut;
      uint24 fee;
      address recipient;
      uint256 amountIn;
      uint256 amountOutMinimum;
      uint160 sqrtPriceLimitX96;
  }
  ```
  Contract tự check deadline: `require(block.timestamp <= deadline)`.
- **Pool fee tier thực tế:**
  - USDC/WETH → `500` (0.05%), liquidity sâu
  - WETH/cbBTC → `3000` (0.3%), pool chính
  - USDC/cbBTC → kiểm tra liquidity trên fork trước khi dùng
  - ✅ Đã kiểm tra on-chain 2026-10-08: USDC/cbBTC fee `500` có liquidity (pool `0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef`), swap trực tiếp USDC→cbBTC chạy được trên fork.
  - ✅ **Chốt 2026-10-08: chỉ chạy pool có stable** — BTC/USDC và ETH/USDC (stable ↔ token trong whitelist). Swap WETH ↔ cbBTC bị chặn (`PairNotAllowed`), dù pool có tồn tại.
- **ETH native trên Uniswap V4 dùng `address(0)` làm currency** (chốt 2026-10-08). Whitelist `address(0)` trong `allowedToken` = cho phép pool ETH native (V4). V3 / SwapRouter02 không swap được ETH native (dùng WETH). ✅ Fork test 2026-10-08: ETH/USDC V4 hookless `500/10` mua + bán chạy được.

> ✅ 2026-10-08: tất cả địa chỉ trên đã kiểm tra on-chain qua RPC (có code, symbol/decimals đúng, Morpho `asset()` = USDC). Vẫn cần cross-check trên basescan trước khi broadcast mainnet. Chi tiết: `docs/instruction/deployment.md`.

---

## 4. Roles

```
┌────────────────────────────────────────────────────────┐
│ SIGNER (≥ 2 address, multisig)                         │
│   Hardware wallet / cold wallet của chủ dự án          │
│   Quyền cao nhất, mọi hành động qua proposal + vote    │
├────────────────────────────────────────────────────────┤
│ OPERATOR (≥ 1 address)                                 │
│   Hot wallet do bot service giữ key                    │
│   CHỈ được submit tx mua/bán + Morpho (stable)         │
│   Tự trả gas bằng ETH trong ví operator                │
├────────────────────────────────────────────────────────┤
│ ANYONE                                                 │
│   Chỉ được gọi depositAndSupply (nạp stable)           │
└────────────────────────────────────────────────────────┘
```

- **Bot logic chạy off-chain** (service riêng), quyết định khi nào mua/bán, rồi dùng key của operator để ký tx. On-chain chỉ có role `operator`, không có role `bot` riêng.
- Một address **không được** vừa là signer vừa là operator.
- **Contract không trả gas.** Người gọi tx (operator) trả gas.

---

## 5. Functions

### 5.1 ANYONE

#### `depositAndSupply(uint256 amount)`
- **Chỉ nhận `stableToken`** (set ở constructor, đổi qua `ChangeStableToken`). Hàm không có tham số token → không ai nạp token khác qua hàm này được.
- `safeTransferFrom(msg.sender → contract, amount)` stable
- Ngay trong cùng tx: `forceApprove(morphoVault, amount)` → `IERC4626(morphoVault).deposit(amount, address(this))` → `forceApprove(morphoVault, 0)`
- Emit `Deposited(from, amount, shares)`
- Không bị chặn bởi `paused` (nạp tiền luôn an toàn).

> Nếu ai đó `transfer` stable thẳng vào contract (không qua hàm này), stable sẽ nằm idle. Operator gọi `morphoDeposit` để đưa lên.

### 5.1b Chống spam token — contract chỉ hoạt động trên token whitelist

**Giới hạn kỹ thuật cần biết:** theo chuẩn ERC20, `transfer()` không gọi vào contract nhận, nên **không contract nào chặn được việc người khác `transfer` token rác vào địa chỉ của mình**. Vì vậy thiết kế theo hướng **"token rác vào được nhưng bị bỏ qua hoàn toàn, không làm contract lỗi"**:

1. **Không có hàm `deposit(address token, ...)` tổng quát.** Chỉ có `depositAndSupply` cho stable.
2. **Mọi hàm chỉ thao tác trên `stableToken` + `allowedToken`** (2 danh sách tách rời: stable = USDC; token mua bán = WETH, cbBTC, tùy chọn `address(0)` = ETH native). Swap: một bên phải là `stableToken`, bên kia phải trong `allowedToken`. `WithdrawBatch` cũng chỉ cho stable hoặc token trong `allowedToken`. Xác định "có phải stable không" luôn bằng **so sánh địa chỉ** với `stableToken`.
3. **Không có logic nào lặp qua "tất cả token đang có trong contract"** hoặc đọc balance của token lạ → token rác không thể làm revert, tốn gas hay ảnh hưởng tính toán.
4. **Không bao giờ gọi vào địa chỉ token chưa whitelist** (token rác có thể có code độc hại trong `transfer`/`balanceOf`).
5. **Từ chối ETH (trừ output swap V4 mua ETH):** không có `fallback()`. `receive()` chỉ nhận ETH khi đang trong `swapExactInputV4` có `tokenOut = address(0)` (cờ `_expectingNative`); mọi lúc khác revert `UnexpectedNative`. (chốt 2026-10-08)
6. **Không có hàm rescue token lạ.** Token rác nằm im vĩnh viễn, vô hại.
7. Chỉ signers mới thêm/xóa token khỏi `allowedToken` qua proposal. `stableToken` không bao giờ nằm trong `allowedToken` (`StableNotTradable`).

### 5.2 OPERATOR (modifier `onlyOperator` + `whenNotPaused` + `nonReentrant`)

#### `swapExactInputV3(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint256 amountOutMinimum, uint256 deadline)`
- Dùng cho **cả mua và bán**, chỉ đổi chiều tokenIn/tokenOut.
- Check:
  - **Một bên phải là `stableToken`** (`tokenIn == stableToken || tokenOut == stableToken`), không có route token ↔ token (`PairNotAllowed`)
  - Bên còn lại phải trong `allowedToken` (`TokenNotAllowed`; stable → stable cũng rơi vào đây vì stable không nằm trong `allowedToken`)
  - Không phải ETH native (`address(0)`) → `NativeNotSupported` (SwapRouter02 chỉ swap ERC20)
  - `amountIn > 0`, `amountOutMinimum > 0`
  - `block.timestamp <= deadline`
  - `allowedFee[fee]` (xem mục 7)
- Atomic approve: `forceApprove(router, amountIn)` → `exactInputSingle(... recipient: address(this) ...)` → `forceApprove(router, 0)`
- **`recipient` luôn là `address(this)`, hardcode, không nhận từ tham số.**
- Nếu `tokenOut == stableToken` (lệnh bán) → tự động deposit số stable nhận được lên Morpho trong cùng tx.
- Emit `Swapped(tokenIn, tokenOut, fee, amountIn, amountOut, 3)`

#### `withdrawAndSwapV3(address tokenOut, uint24 fee, uint256 stableAmount, uint256 amountOutMinimum, uint256 deadline)`
- Lệnh **mua** gộp: rút **đúng `stableAmount`** từ Morpho → swap stable → tokenOut, tất cả trong 1 tx.
- `IERC4626(morphoVault).withdraw(stableAmount, address(this), address(this))`
- Sau đó cùng logic/check như `swapExactInputV3` với `tokenIn = stableToken`.
- Nếu swap fail → toàn bộ tx revert, stable vẫn ở Morpho.

#### `morphoDeposit(uint256 amount)`
- Chỉ stable. Đưa stable idle trong contract lên Morpho.
- `amount <= IERC20(stableToken).balanceOf(address(this))`

#### `morphoWithdraw(uint256 amount)`
- Chỉ stable. Rút **đúng `amount`** từ Morpho về contract.
- `receiver` và `owner` luôn là `address(this)`.

#### `swapExactInputV4(address tokenIn, address tokenOut, uint24 fee, int24 tickSpacing, uint256 amountIn, uint256 amountOutMinimum, uint256 deadline)` (implemented 2026-10-08, owner request)
- Option bổ sung cho V3, cùng quy tắc: **một bên là `stableToken`**, bên kia trong `allowedToken`, `amountIn > 0`, `amountOutMinimum > 0`, `block.timestamp <= deadline`, `allowedFee[fee]` (dùng chung list với V3), **`allowedTickSpacing[tickSpacing]`** (xem mục 7). `amountIn` / `amountOutMinimum` ≤ `uint128.max` (không truncate).
- Flow: `forceApprove(tokenIn → Permit2, amountIn)` → `IPermit2.approve(tokenIn, universalRouter, uint160(amountIn), uint48(block.timestamp))` → contract **tự build** commands/inputs cho `UniversalRouter.execute` (command `V4_SWAP`, actions `SWAP_EXACT_IN_SINGLE` + `SETTLE_ALL(tokenIn, amountIn)` + `TAKE_ALL(tokenOut, amountOutMinimum)`) → reset Permit2 allowance (`approve(..., 0, 0)`) và ERC20 allowance về 0.
- **Không nhận raw calldata từ operator.** Operator chỉ truyền: tokenIn, tokenOut, fee, tickSpacing, amountIn, amountOutMinimum, deadline.
- `PoolKey`: `currency0/1` = 2 token sắp theo address, `zeroForOne = tokenIn < tokenOut`, `hooks` **hardcode `address(0)`** (không cho pool có hook lạ), `hookData = ""`.
- Output: `TAKE_ALL` trả cho `msg.sender` của UniversalRouter = chính vault (không có tham số recipient).
- Kiểm tra balance trước/sau: tokenOut tăng ≥ minOut (`InsufficientOutput`), tokenIn giảm ≤ amountIn (`ExcessiveInput`).
- Nếu `tokenOut == stableToken` (lệnh bán) → tự deposit số stable nhận được lên Morpho (giống V3). Emit `Swapped(..., version = 4)`.
- Không có `withdrawAndSwapV4`: mua qua V4 = `morphoWithdraw` rồi `swapExactInputV4` (2 tx).
- **ETH native (`address(0)`, nếu đã whitelist)** (chốt 2026-10-08):
  - `address(0)` luôn là `currency0` trong `PoolKey` (sort tự nhiên).
  - Bán ETH: **không approve gì cả** — gửi đúng `amountIn` làm `msg.value` cho `UniversalRouter.execute`; `SETTLE_ALL` trả PoolManager từ số ETH đó.
  - Mua ETH: `TAKE_ALL` → PoolManager gửi ETH về vault → `receive()` chỉ nhận khi cờ `_expectingNative` bật (bật ngay trước `execute`, tắt ngay sau, trong hàm `nonReentrant`).
  - Balance trước/sau đọc bằng `address(this).balance`. ETH mua về nằm yên trong contract.

### 5.3 SIGNER — hệ thống proposal

#### Cơ chế chung
- `propose(ProposalType, bytes data)` → tạo proposal, người tạo tự động approve.
- `approve(uint256 id)` → signer khác vote.
- Khi số approve ≥ threshold → **tự động execute**.
- `cancel(uint256 id)` → `onlySigner`, chỉ người tạo **và người tạo vẫn đang là signer**, khi chưa execute (chốt 2026-10-08: mọi hàm thay đổi state phải check role — signer đã bị xóa không còn quyền gì).
- Proposal hết hạn sau **7 ngày**.
- `reject(uint256 id)` → signer vote **không đồng ý** (chốt 2026-10-08). Khi số reject hợp lệ ≥ threshold (≥ 50% signers hiện tại, cùng công thức `getThreshold()`) → proposal bị **hủy** (`cancelled = true`, emit `ProposalCancelled`), không bao giờ dùng lại được. Reject cũng đếm lại theo signer hiện tại.
- Proposal của người khác **chỉ bị hủy khi ≥ 50% signers reject** → 1 signer không thể spam hủy. Tạo proposal mới **không ảnh hưởng** proposal đang chờ (nhiều proposal chờ song song, mỗi cái tối đa 7 ngày).
- Mỗi signer chỉ vote 1 lần / proposal: **hoặc approve hoặc reject** (`AlreadyVoted`). Người tạo đã tự approve nên không reject được — muốn rút proposal của mình thì dùng `cancel`.
- **Khi execute, đếm lại số vote của các address hiện vẫn là signer** (vote của signer đã bị xóa không được tính).
- Helper `proposeXxx(...)` phải gọi hàm **internal** `_propose`, **KHÔNG dùng `this.propose(...)`** (sẽ làm `msg.sender` thành chính contract).

#### Threshold (đã chốt)
- **≥ 50% signers đồng ý**. Công thức: `threshold = (signerCount + 1) / 2` (làm tròn lên).

| signers | threshold |
|---|---|
| 2 | 1 |
| 3 | 2 |
| 4 | 2 |
| 5 | 3 |

- Viết thành hàm riêng `getThreshold()`. Không thêm logic phức tạp khác.

#### Các loại proposal

| ProposalType | data | Ràng buộc |
|---|---|---|
| `WithdrawBatch` | `(address[] tokens, uint256[] amounts, address to)` | `to` phải nằm trong `isWithdrawAddress`. Mỗi token phải là `stableToken` hoặc nằm trong `allowedToken`. Mảng cùng độ dài, không rỗng. `amount = type(uint256).max` nghĩa là rút hết token đó. Nếu token là stable và số dư contract không đủ → tự rút phần thiếu từ Morpho (rút hết = `redeem` toàn bộ shares). Token `address(0)` = ETH native, gửi bằng `call{value}("")` (calldata rỗng) tới `to`; fail → `NativeTransferFailed`. |
| `AddWithdrawAddress` | `address` | khác `address(0)` |
| `RemoveWithdrawAddress` | `address` | — |
| `AddSigner` | `address` | không phải operator, chưa là signer |
| `RemoveSigner` | `address` | sau khi xóa còn ≥ `MIN_SIGNERS = 2` |
| `AddOperator` | `address` | không phải signer |
| `RemoveOperator` | `address` | — (cho phép xóa hết operator) |
| `ChangeMorphoVault` | `address newVault` | Chỉ check `newVault != 0` và `!= vault hiện tại`. **Không check factory / `asset()` on-chain** — owner quyết định: vault là địa chỉ multisig chỉ định, signers tự kiểm tra trước khi approve. Đổi được **chỉ** qua proposal đủ threshold. **Tự migrate:** `redeem` toàn bộ shares ở vault cũ → deposit toàn bộ stable vào vault mới. |
| `AddToken` / `RemoveToken` | `address` | Token mua bán. `address(0)` hợp lệ (= ETH native, chỉ dùng được ở V4). `AddToken(stableToken)` → `StableNotTradable`. |
| `SetAllowedFee` | `(uint24 fee, bool allowed)` | — |
| `Unpause` | — | Mở lại hoạt động cho operator. |
| `ChangeUniV3Router` | `address` | `!= 0`, `!= router hiện tại`. Không validate on-chain — signers tự kiểm tra trước khi approve (router nhận `tokenIn` khi swap). Không cần migrate allowance vì contract không có standing approval. (chốt 2026-10-08) |
| `ChangePermit2` | `address` | `!= 0`, `!= hiện tại`. (chốt 2026-10-08) |
| `ChangeUniversalRouter` | `address` | `!= 0`, `!= hiện tại`. (chốt 2026-10-08) |
| `SetAllowedTickSpacing` | `(int24 tickSpacing, bool allowed)` | `1 <= tickSpacing <= 32767`. Cho V4. (chốt 2026-10-08) |
| `ChangeStableToken` | `(address newStable, address newVault, address to)` | `newStable`, `newVault != 0`; `newStable != stableToken`; `newVault != morphoVault`; `newStable` không nằm trong `allowedToken`; `to` trong `isWithdrawAddress`. **Rút sạch rồi mới đổi**: `redeem` toàn bộ shares ở vault cũ → chuyển **toàn bộ** stable cũ (idle + vừa redeem) về `to` → set `stableToken = newStable`, `morphoVault = newVault`. `newVault` phải là Morpho vault của `newStable` — không validate on-chain. (chốt 2026-10-08) |

> 3 loại proposal đổi địa chỉ protocol, rồi `SetAllowedTickSpacing`, `ChangeStableToken`, được **thêm vào cuối enum** (sau `Unpause`) để giá trị enum cũ không đổi.
> Sweep nằm **trong** `ChangeStableToken` (không phải điều kiện "balance = 0" trước khi đổi) để không ai chặn được việc đổi bằng cách gửi 1 wei stable cũ / gọi `depositAndSupply`. Sau khi đổi, stable cũ chỉ là token chưa whitelist (bị bỏ qua như token rác).

> **Không có proposal approve token tùy ý.** Mọi approve chỉ xảy ra atomic bên trong hàm swap/Morpho (approve đúng số → dùng → reset 0). Không tồn tại standing approval → hacker không thể "approve linh tinh".

#### Emergency pause (đã chốt)
- `pause()` — `onlySigner`, **1 signer gọi là pause ngay lập tức, không cần vote**.
- **Unpause phải qua proposal `Unpause`** (đủ threshold).
- Khi `paused`: mọi hàm operator revert. `depositAndSupply` và hệ thống proposal (kể cả `WithdrawBatch`) vẫn hoạt động.
- Lý do: pause không làm mất tiền → cho 1 người làm để phản ứng nhanh khi phát hiện operator bị hack.

---

## 6. State

```solidity
// Tokens & protocols
address public constant NATIVE = address(0); // ETH native (V4 currency id)
address public stableToken;                // stable duy nhất, signers đổi được (ChangeStableToken, rút sạch trước)
address public morphoVault;                // signers đổi được (ChangeMorphoVault / ChangeStableToken)
address public uniV3Router;                // signers đổi được (ChangeUniV3Router)
address public permit2;                    // V4, signers đổi được (ChangePermit2)
address public universalRouter;            // V4, signers đổi được (ChangeUniversalRouter)

// Roles
mapping(address => bool) public isSigner;
address[] public signers;
mapping(address => bool) public isOperator;
mapping(address => bool) public isWithdrawAddress;

// Whitelist
mapping(address => bool) public allowedToken;   // token mua bán: WETH, cbBTC, (address(0) = ETH native). KHÔNG chứa stable
mapping(uint24 => bool) public allowedFee;      // 100, 500, 3000, 10000 (V3 + V4)
mapping(int24 => bool) public allowedTickSpacing; // V4: 10, 60, ...

// Safety
bool public paused;
bool internal _expectingNative;                 // chỉ true trong swap V4 mua ETH native -> receive() nhận

// Proposals
struct Proposal { ProposalType pType; bytes data; address proposer; uint64 createdAt; bool executed; bool cancelled; }
mapping(uint256 => Proposal) public proposals;
mapping(uint256 => mapping(address => bool)) public hasApproved;
uint256 public proposalCount;
```

Constructor nhận: `stableToken, uniV3Router, permit2, universalRouter, morphoVault, signers[], operators[], withdrawAddresses[], tokens[], fees[], tickSpacings[]`. `tokens[]` là token mua bán, **không chứa stable** (`StableNotTradable`), có thể chứa `address(0)` (ETH native). Validate protocol/stable không `address(0)`, không trùng, signers ≥ 2 (deploy ban đầu tối thiểu 2 signer), signer ∩ operator = ∅. `morphoVault` không được validate on-chain (không check factory / `asset()`); deploy script vẫn pre-flight `asset() == stableToken` off-chain.

---

## 7. Giới hạn an toàn cho operator (đã chốt)

**Chỉ dùng `allowedFee`.** Không làm giới hạn số lượng mỗi lệnh/mỗi ngày, không làm TWAP check.

- `allowedFee[fee]` — operator chỉ được swap qua các fee tier đã whitelist. Mặc định set ở constructor: `500` (0.05%) và `3000` (0.3%).
- Bot tự chọn fee trong danh sách này.
- Signers thêm/bớt fee tier qua proposal `SetAllowedFee`.
- Slippage do bot off-chain kiểm soát qua `amountOutMinimum` (contract chỉ check `> 0`).
- **V4 thêm `allowedTickSpacing[tickSpacing]`** (chốt 2026-10-08): ở V4 tick spacing chọn tự do theo pool (không cố định theo fee như V3). Set ở constructor (deploy mặc định `10, 60` — ứng với fee 500 / 3000 trên Base), signers thêm/bớt qua proposal `SetAllowedTickSpacing`. Whitelist global, độc lập với `allowedFee`.

---

## 8. Events

```
Deposited(address indexed from, uint256 amount, uint256 shares)
MorphoDeposited(uint256 assets, uint256 shares)
MorphoWithdrawn(uint256 assets, uint256 shares)
Swapped(address indexed tokenIn, address indexed tokenOut, uint24 fee, uint256 amountIn, uint256 amountOut, uint8 version)
ProposalCreated(uint256 indexed id, ProposalType pType, address indexed proposer)
ProposalApproved(uint256 indexed id, address indexed signer)
ProposalRejected(uint256 indexed id, address indexed signer)
ProposalExecuted(uint256 indexed id)
ProposalCancelled(uint256 indexed id)
Withdrawn(address indexed token, address indexed to, uint256 amount)
SignerAdded / SignerRemoved / OperatorAdded / OperatorRemoved
WithdrawAddressAdded / WithdrawAddressRemoved
MorphoVaultChanged(address oldVault, address newVault, uint256 migratedAssets)
UniV3RouterChanged(address oldRouter, address newRouter)
Permit2Changed(address oldPermit2, address newPermit2)
UniversalRouterChanged(address oldRouter, address newRouter)
StableTokenChanged(address oldStable, address newStable, address oldMorphoVault, address newMorphoVault, uint256 sweptAmount)
TokenAllowed(address token, bool allowed)
FeeAllowed(uint24 fee, bool allowed)
Paused(address indexed by)
Unpaused()
```

## 9. View functions

- `getSigners()`, `getThreshold()`
- `totalStable()` = stable idle + `IERC4626(morphoVault).convertToAssets(shares)`
- `getBalances()` → `(stableIdle, stableInMorpho, address[] tokens, uint256[] balances)` — stable báo riêng; `tokens` = token mua bán trong whitelist (WETH, cbBTC, …; `address(0)` → `address(this).balance`). Chỉ đọc token đã whitelist (bất biến #12).
- `getAllowedTokens()` → danh sách token mua bán (không có stable)
- `getProposal(id)` → type, data, số vote hợp lệ hiện tại, threshold, executed, cancelled, expired
- `getRejections(id)` → số reject hợp lệ hiện tại

---

## 10. Bất biến bảo mật (phải có test cho từng điều)

1. Operator **không thể** làm token rời contract, ngoại trừ: tokenIn đi vào router trong swap (ETH native: `msg.value` cho UniversalRouter), stable đi vào Morpho vault.
2. Mọi output swap và Morpho withdraw **luôn về `address(this)`**.
3. Sau mỗi tx, allowance của contract cho router / Permit2 / Morpho **= 0**.
4. Token chỉ ra ngoài qua `WithdrawBatch` (hoặc sweep của `ChangeStableToken`) đã đủ vote, và chỉ về `isWithdrawAddress`. (Ngoại lệ: `ChangeMorphoVault` gửi stable vào vault mới, và swap gửi `tokenIn` vào router — các địa chỉ này chỉ đổi được qua proposal đủ threshold; signers chịu trách nhiệm kiểm tra trước khi approve.)
5. Số signer **không bao giờ < 2**.
6. Vote của signer đã bị xóa không được tính.
7. Proposal hết hạn / đã execute / đã cancel không thể execute.
8. Khi `paused`, mọi hàm operator revert. 1 signer pause được ngay; unpause chỉ qua proposal.
9. Không có hàm `delegatecall`, `selfdestruct`, hay gọi địa chỉ tùy ý với calldata tùy ý.
10. Contract **từ chối ETH**, trừ đúng lúc swap V4 mua ETH native (`receive()` chỉ mở khi `_expectingNative`); không có `fallback`. Router đẩy ETH vào lúc swap khác → revert.
11. Chỉ stable nạp vào được qua `depositAndSupply`. Mọi hàm swap/withdraw revert với token không phải `stableToken` / ngoài `allowedToken`.
12. Token rác bị `transfer` thẳng vào contract **không làm bất kỳ hàm nào revert hay thay đổi hành vi** (test: transfer token ERC20 giả có `transfer`/`balanceOf` revert vào contract, rồi chạy lại toàn bộ flow chính).

---

## 11. Cấu trúc project

```
dca-vault/
├── foundry.toml
├── .env.example            # BASE_RPC_URL, PRIVATE_KEY_DEPLOYER, BASESCAN_API_KEY
├── src/
│   ├── DCAVault.sol             # final contract + constructor (inherits the modules below)
│   ├── vault/
│   │   ├── DCAVaultStorage.sol  # types, constants, immutables, state, events, errors, modifiers
│   │   ├── DCAVaultRoles.sol    # signers / operators / withdraw addresses / token, fee & tick-spacing whitelists
│   │   ├── DCAVaultMorpho.sol   # depositAndSupply, morphoDeposit/Withdraw, ChangeMorphoVault / ChangeStableToken
│   │   ├── DCAVaultSwap.sol     # shared swap checks + settlement (base of V3 / V4)
│   │   ├── DCAVaultSwapV3.sol   # swapExactInputV3, withdrawAndSwapV3
│   │   ├── DCAVaultSwapV4.sol   # swapExactInputV4 (UniversalRouter + Permit2)
│   │   └── DCAVaultProposals.sol # pause, propose/approve/cancel, execute, WithdrawBatch
│   └── interfaces/
│       ├── ISwapRouter02.sol
│       ├── IPermit2.sol
│       ├── IUniversalRouter.sol
│       └── IV4Router.sol        # V4 PoolKey / ExactInputSingleParams
├── test/
│   ├── DCAVault.t.sol           # unit test roles, proposals, limits
│   ├── DCAVault.fork.t.sol      # fork Base: deposit → Morpho, withdrawAndSwap, sell → Morpho, batch withdraw, đổi vault
│   └── DCAVault.security.t.sol  # test các bất biến mục 10, operator độc hại
└── script/
    └── Deploy.s.sol             # đọc địa chỉ từ env/config, deploy, verify basescan
```

Chạy test fork: `forge test --fork-url $BASE_RPC_URL -vvv`

---

## 12. Thứ tự triển khai

**Phase 1 (làm trước):**
1. Setup Foundry + OpenZeppelin
2. Roles + proposal system + threshold
3. `depositAndSupply`, `morphoDeposit`, `morphoWithdraw`
4. `swapExactInputV3`, `withdrawAndSwapV3` (kèm auto-deposit khi bán ra USDC)
5. `WithdrawBatch`, `ChangeMorphoVault` (có migrate)
6. `allowedFee`, `pause()` (1 signer) + proposal `Unpause`
7. Toàn bộ test (unit + fork + security)
8. Deploy script

**Phase 2:** (làm sớm theo yêu cầu owner 2026-10-08 — đã xong)
- `swapExactInputV4` qua UniversalRouter + Permit2, `allowedTickSpacing` + proposal `SetAllowedTickSpacing`

**Ngoài phạm vi file này:** bot service off-chain (check điều kiện DCA, tính `amountOutMinimum` bằng QuoterV2, ký tx bằng key operator). Sẽ có spec riêng.

---

## 13. Sau khi deploy — checklist vận hành

1. Verify contract trên basescan.
2. Kiểm tra `getSigners()`, operators, withdraw addresses, tokens, fees, `morphoVault` đúng như mong muốn.
3. Nạp một ít ETH (~0.01–0.02 ETH) vào **ví operator** để trả gas.
4. Chủ dự án gọi `stable.approve(vault, amount)` (USDC) rồi `depositAndSupply(amount)` từ ví chính → kiểm tra shares trên Morpho.
5. Test 1 lệnh mua nhỏ (vd 5 USDC → WETH) bằng operator.
6. Test `pause()` bằng 1 signer, rồi proposal `Unpause`.
7. Test 1 proposal `WithdrawBatch` nhỏ về ví chính.
8. **Revoke** các approval unlimited cũ trên EOA (cbBTC/WETH/USDC → Uniswap V3 Router, USDC → Permit2, USDC → Morpho Bundler).
9. Bật bot service.

---

## 14. Quy tắc cho Claude Code

- Hỏi lại chủ dự án mọi mục `⚠️ CẦN XÁC NHẬN` trước khi implement phần đó.
- Không tự thêm tính năng ngoài spec. Không thêm hàm cho operator gọi địa chỉ/calldata tùy ý.
- Comment code bằng tiếng Việt hoặc tiếng Anh ngắn gọn, giải thích **tại sao** ở các chỗ liên quan bảo mật.
- Mỗi bước phase 1 xong → chạy `forge build` + `forge test` trước khi qua bước tiếp.
- Contract này cần **audit bởi bên thứ ba** trước khi đưa số tiền lớn lên mainnet. Giai đoạn đầu chỉ chạy với số tiền nhỏ.

---

## 15. Ghi chú implementation (Phase 1, 2026-10-08)

Các quyết định chi tiết khi code, không đổi hành vi chính của spec:

- **Proposal id bắt đầu từ 1** (id 0 luôn là "không tồn tại").
- **Stable tách khỏi `tokens[]`** (chốt 2026-10-08): `tokens[]` chỉ là token mua bán, chứa stable → revert `StableNotTradable`; trùng token/fee → revert.
- **`WithdrawBatch`: amount = 0 bị từ chối.** Token trùng trong cùng batch được xử lý tuần tự.
- **Swap đo output bằng balance trước/sau** (không tin giá trị trả về của router) và revert `InsufficientOutput` nếu < `amountOutMinimum`. `sqrtPriceLimitX96 = 0`.
- **Bán ra stable chỉ deposit đúng số stable nhận được**, stable idle có sẵn không bị đụng.
- **`ChangeMorphoVault` deposit toàn bộ stable balance** (phần redeem + stable idle) vào vault mới.
- **Validate 2 lần**: lúc propose (từ chối sớm) và lúc execute (state có thể đã đổi, vd. withdraw address bị xóa).
- **Signer bị xóa rồi được thêm lại**: vote cũ (`hasApproved` / `hasRejected`) của họ trên proposal còn hạn sẽ được tính lại.
- **Morpho vault không validate on-chain** (quyết định owner 2026-10-08): contract chỉ supply / withdraw vào địa chỉ `morphoVault` đã set. Địa chỉ này chỉ đổi được qua `ChangeMorphoVault` đủ threshold, nên một signer / operator / người ngoài không đổi được. Signers phải kiểm tra `newVault` (là Morpho vault thật, `asset()` = stable, curator) trước khi approve.
- **`swapExactInputV4` đã implement** (owner request 2026-10-08, trước đó là stub); `permit2` / `universalRouter` là state, đổi qua proposal. Pool V4 hookless có thanh khoản trên Base (check 2026-10-08): WETH/USDC `500/10`, `3000/60`; USDC/cbBTC `500/10`.
- **Propose-time từ chối sớm** `ChangeMorphoVault` / `ChangeUniV3Router` / `ChangePermit2` / `ChangeUniversalRouter` trỏ vào chính địa chỉ hiện tại (execute vẫn check lại).

## 16. Rủi ro đã chấp nhận (security review 2026-10-08)

Owner đã xem xét và **chọn giữ nguyên** theo spec. Ghi lại để audit / vận hành biết:

1. **Operator bị hack có thể phá giá trị qua sandwich.** Contract chỉ check `amountOutMinimum > 0`. Kẻ có key operator có thể bơm giá pool rồi gọi `withdrawAndSwapV3(toàn bộ USDC, minOut = 1)` (hoặc bán toàn bộ WETH/cbBTC) và back-run → token không "rời" contract trực tiếp nhưng gần như toàn bộ giá trị bị lấy. `allowedFee` / `allowedTickSpacing` là global, không theo cặp → operator có thể chọn pool mỏng (dễ thao túng hơn), cả V3 lẫn V4. Biện pháp hiện tại: signer `pause()` ngay khi phát hiện, giữ ít operator, monitor `Swapped` event. Phương án nếu cần sau: TWAP check on-chain hoặc cap theo ngày.
2. **`ChangeMorphoVault` all-or-nothing.** Nếu vault cũ pause / thiếu thanh khoản / bị hack, `redeem` toàn bộ revert → không đổi vault được; `depositAndSupply` và lệnh bán vẫn đẩy USDC vào vault cũ. Biện pháp: signer `pause()` để chặn bán ra USDC; chờ vault cũ có thanh khoản.
3. **2 signer → threshold 1.** Một signer bị lộ key là tự mình làm được mọi thứ (AddWithdrawAddress + WithdrawBatch, AddSigner, ChangeUniV3Router sang router độc…). Khuyến nghị deploy ≥ 3 signer (threshold 2).
4. **Proposal `Unpause` cũ còn hạn** (tạo trong lần pause trước) vẫn approve được trong lần pause sau. Signers nên `cancel` / `reject` các proposal `Unpause` thừa.
5. **Router / Morpho vault / Permit2 / UniversalRouter / stable không validate on-chain** — đủ threshold là đổi được sang bất kỳ địa chỉ nào; trust ngang với `AddWithdrawAddress` + `WithdrawBatch`.
6. **`ChangeStableToken` all-or-nothing** (giống #2): nếu vault cũ không redeem được toàn bộ → không đổi stable được. Stable cũ gửi tới `to` có thể fail nếu token đó pause/blacklist vault.
7. **ETH native**: `WithdrawBatch` ETH tới một contract không có `receive()` → cả batch revert (`NativeTransferFailed`); chọn withdraw address là EOA / Safe nhận được ETH.

