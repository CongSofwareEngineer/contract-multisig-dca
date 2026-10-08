# DCA Vault — Spec thiết kế (Base chain)

> File này là spec cho Claude Code. **Đọc hết trước khi code.** Mọi điểm đánh dấu `⚠️ CẦN XÁC NHẬN` phải hỏi lại chủ dự án trước khi implement.

---

## 1. Mục tiêu

Xây một smart contract vault trên **Base** để DCA **cbBTC** và **WETH** liên tục trong ~3 năm:

- USDC nhàn rỗi **luôn** nằm trên **MetaMorpho Vault** (ERC-4626) để lấy yield.
- Khi bot off-chain thấy đủ điều kiện → rút **đúng số USDC cần** từ Morpho → swap trên Uniswap.
- cbBTC / WETH sau khi mua **nằm yên trong contract**, không đưa đi đâu.
- Không ai (kể cả operator bị hack) có thể chuyển token ra ngoài, trừ khi multisig signers đồng ý và chỉ về địa chỉ đã whitelist.

Thay thế cho mô hình EOA hiện tại (approve unlimited cho Uniswap V3 Router, Permit2, Morpho Bundler → rủi ro lộ private key).

---

## 2. Tech stack

- **Ngôn ngữ:** Solidity `^0.8.24`
- **Framework:** Foundry (forge, cast, anvil)
- **Thư viện:** OpenZeppelin Contracts v5 (`SafeERC20`, `ReentrancyGuard`, `IERC4626`)
- **Chain:** Base mainnet (chainId `8453`), test trên fork Base mainnet bằng `anvil --fork-url`
- **Không dùng proxy/upgradeable.** Contract immutable, mọi thay đổi cấu hình qua multisig proposal.

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
| MetaMorpho Vault USDC | `0xbeeff7aE5E00Aae3Db302e4B0d8C883810a58100` | Ví dụ Steakhouse USDC `0xbeeff7aE5E00Aae3Db302e4B0d8C883810a58100` |

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
  - ✅ Đã kiểm tra on-chain 2026-10-08: USDC/cbBTC fee `500` có liquidity (pool `0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef`), swap trực tiếp USDC→cbBTC chạy được trên fork. WETH/cbBTC fee `500` cũng có liquidity tương đương `3000`.

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
│   CHỈ được submit tx mua/bán + Morpho USDC             │
│   Tự trả gas bằng ETH trong ví operator                │
├────────────────────────────────────────────────────────┤
│ ANYONE                                                 │
│   Chỉ được gọi depositAndSupply (nạp USDC)             │
└────────────────────────────────────────────────────────┘
```

- **Bot logic chạy off-chain** (service riêng), quyết định khi nào mua/bán, rồi dùng key của operator để ký tx. On-chain chỉ có role `operator`, không có role `bot` riêng.
- Một address **không được** vừa là signer vừa là operator.
- **Contract không trả gas.** Người gọi tx (operator) trả gas.

---

## 5. Functions

### 5.1 ANYONE

#### `depositAndSupply(uint256 amount)`
- **Chỉ nhận USDC** (địa chỉ `usdc` immutable, set ở constructor). Hàm không có tham số token → không ai nạp token khác qua hàm này được.
- `safeTransferFrom(msg.sender → contract, amount)` USDC
- Ngay trong cùng tx: `forceApprove(morphoVault, amount)` → `IERC4626(morphoVault).deposit(amount, address(this))` → `forceApprove(morphoVault, 0)`
- Emit `Deposited(from, amount, shares)`
- Không bị chặn bởi `paused` (nạp tiền luôn an toàn).

> Nếu ai đó `transfer` USDC thẳng vào contract (không qua hàm này), USDC sẽ nằm idle. Operator gọi `morphoDeposit` để đưa lên.

### 5.1b Chống spam token — contract chỉ hoạt động trên token whitelist

**Giới hạn kỹ thuật cần biết:** theo chuẩn ERC20, `transfer()` không gọi vào contract nhận, nên **không contract nào chặn được việc người khác `transfer` token rác vào địa chỉ của mình**. Vì vậy thiết kế theo hướng **"token rác vào được nhưng bị bỏ qua hoàn toàn, không làm contract lỗi"**:

1. **Không có hàm `deposit(address token, ...)` tổng quát.** Chỉ có `depositAndSupply` cho USDC.
2. **Mọi hàm chỉ thao tác trên `allowedToken`** (USDC, WETH, cbBTC). Swap check cả tokenIn và tokenOut. `WithdrawBatch` cũng chỉ cho token trong `allowedToken`.
3. **Không có logic nào lặp qua "tất cả token đang có trong contract"** hoặc đọc balance của token lạ → token rác không thể làm revert, tốn gas hay ảnh hưởng tính toán.
4. **Không bao giờ gọi vào địa chỉ token chưa whitelist** (token rác có thể có code độc hại trong `transfer`/`balanceOf`).
5. **Từ chối ETH:** không có `receive()` / `fallback()` payable → mọi lệnh gửi ETH thường vào contract đều revert.
6. **Không có hàm rescue token lạ.** Token rác nằm im vĩnh viễn, vô hại.
7. Chỉ signers mới thêm/xóa token khỏi `allowedToken` qua proposal. USDC không bao giờ bị xóa khỏi danh sách.

### 5.2 OPERATOR (modifier `onlyOperator` + `whenNotPaused` + `nonReentrant`)

#### `swapExactInputV3(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint256 amountOutMinimum, uint256 deadline)`
- Dùng cho **cả mua và bán**, chỉ đổi chiều tokenIn/tokenOut.
- Check:
  - `allowedToken[tokenIn] && allowedToken[tokenOut]`, `tokenIn != tokenOut`
  - `amountIn > 0`, `amountOutMinimum > 0`
  - `block.timestamp <= deadline`
  - `allowedFee[fee]` (xem mục 7)
- Atomic approve: `forceApprove(router, amountIn)` → `exactInputSingle(... recipient: address(this) ...)` → `forceApprove(router, 0)`
- **`recipient` luôn là `address(this)`, hardcode, không nhận từ tham số.**
- Nếu `tokenOut == USDC` (lệnh bán) → tự động deposit số USDC nhận được lên Morpho trong cùng tx.
- Emit `Swapped(tokenIn, tokenOut, fee, amountIn, amountOut, "V3")`

#### `withdrawAndSwapV3(address tokenOut, uint24 fee, uint256 usdcAmount, uint256 amountOutMinimum, uint256 deadline)`
- Lệnh **mua** gộp: rút **đúng `usdcAmount`** từ Morpho → swap USDC → tokenOut, tất cả trong 1 tx.
- `IERC4626(morphoVault).withdraw(usdcAmount, address(this), address(this))`
- Sau đó cùng logic/check như `swapExactInputV3` với `tokenIn = USDC`.
- Nếu swap fail → toàn bộ tx revert, USDC vẫn ở Morpho.

#### `morphoDeposit(uint256 amount)`
- Chỉ USDC. Đưa USDC idle trong contract lên Morpho.
- `amount <= IERC20(usdc).balanceOf(address(this))`

#### `morphoWithdraw(uint256 amount)`
- Chỉ USDC. Rút **đúng `amount`** từ Morpho về contract.
- `receiver` và `owner` luôn là `address(this)`.

#### `swapExactInputV4(...)` — PHASE 2
- Option cho tương lai, V3 là chính.
- Flow: contract `approve(USDC → Permit2, amountIn)` → `IPermit2.approve(token, universalRouter, uint160(amountIn), uint48(block.timestamp))` → contract **tự build** commands/inputs cho `UniversalRouter.execute` (command `V4_SWAP`, actions `SWAP_EXACT_IN_SINGLE` + `SETTLE_ALL` + `TAKE_ALL`).
- **Không nhận raw calldata từ operator.** Operator chỉ truyền: tokenIn, tokenOut, fee, tickSpacing, amountIn, amountOutMinimum, deadline.
- `hooks` trong PoolKey bắt buộc `address(0)` (không cho pool có hook lạ).
- Kiểm tra balance trước/sau: tokenOut tăng ≥ minOut, tokenIn giảm ≤ amountIn.
- Reset allowance Permit2 và ERC20 về 0 sau swap.
- Phase 1 chỉ cần để sẵn interface/stub hoặc bỏ qua; implement ở phase 2.

### 5.3 SIGNER — hệ thống proposal

#### Cơ chế chung
- `propose(ProposalType, bytes data)` → tạo proposal, người tạo tự động approve.
- `approve(uint256 id)` → signer khác vote.
- Khi số approve ≥ threshold → **tự động execute**.
- `cancel(uint256 id)` → chỉ người tạo, khi chưa execute.
- Proposal hết hạn sau **7 ngày**.
- Mỗi signer chỉ vote 1 lần / proposal.
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
| `WithdrawBatch` | `(address[] tokens, uint256[] amounts, address to)` | `to` phải nằm trong `isWithdrawAddress`. Mọi token phải nằm trong `allowedToken`. Mảng cùng độ dài, không rỗng. `amount = type(uint256).max` nghĩa là rút hết token đó. Nếu token là USDC và số dư contract không đủ → tự rút phần thiếu từ Morpho (rút hết = `redeem` toàn bộ shares). |
| `AddWithdrawAddress` | `address` | khác `address(0)` |
| `RemoveWithdrawAddress` | `address` | — |
| `AddSigner` | `address` | không phải operator, chưa là signer |
| `RemoveSigner` | `address` | sau khi xóa còn ≥ `MIN_SIGNERS = 2` |
| `AddOperator` | `address` | không phải signer |
| `RemoveOperator` | `address` | — (cho phép xóa hết operator) |
| `ChangeMorphoVault` | `address newVault` | `IERC4626(newVault).asset() == usdc`. **Tự migrate:** `redeem` toàn bộ shares ở vault cũ → deposit toàn bộ USDC vào vault mới. |
| `AddToken` / `RemoveToken` | `address` | Không cho remove USDC. |
| `SetAllowedFee` | `(uint24 fee, bool allowed)` | — |
| `Unpause` | — | Mở lại hoạt động cho operator. |

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
address public immutable usdc;
address public immutable uniV3Router;
address public immutable permit2;          // V4
address public immutable universalRouter;  // V4
address public morphoVault;                // signers đổi được

// Roles
mapping(address => bool) public isSigner;
address[] public signers;
mapping(address => bool) public isOperator;
mapping(address => bool) public isWithdrawAddress;

// Whitelist
mapping(address => bool) public allowedToken;   // USDC, WETH, cbBTC
mapping(uint24 => bool) public allowedFee;      // 100, 500, 3000, 10000

// Safety
bool public paused;

// Proposals
struct Proposal { ProposalType pType; bytes data; address proposer; uint64 createdAt; bool executed; bool cancelled; }
mapping(uint256 => Proposal) public proposals;
mapping(uint256 => mapping(address => bool)) public hasApproved;
uint256 public proposalCount;
```

Constructor nhận: `usdc, uniV3Router, permit2, universalRouter, morphoVault, signers[], operators[], withdrawAddresses[], tokens[], fees[]`. Validate không `address(0)`, không trùng, signers ≥ 2, signer ∩ operator = ∅, `IERC4626(morphoVault).asset() == usdc`.

---

## 7. Giới hạn an toàn cho operator (đã chốt)

**Chỉ dùng `allowedFee`.** Không làm giới hạn số lượng mỗi lệnh/mỗi ngày, không làm TWAP check.

- `allowedFee[fee]` — operator chỉ được swap qua các fee tier đã whitelist. Mặc định set ở constructor: `500` (0.05%) và `3000` (0.3%).
- Bot tự chọn fee trong danh sách này.
- Signers thêm/bớt fee tier qua proposal `SetAllowedFee`.
- Slippage do bot off-chain kiểm soát qua `amountOutMinimum` (contract chỉ check `> 0`).

---

## 8. Events

```
Deposited(address indexed from, uint256 usdcAmount, uint256 shares)
MorphoDeposited(uint256 assets, uint256 shares)
MorphoWithdrawn(uint256 assets, uint256 shares)
Swapped(address indexed tokenIn, address indexed tokenOut, uint24 fee, uint256 amountIn, uint256 amountOut, uint8 version)
ProposalCreated(uint256 indexed id, ProposalType pType, address indexed proposer)
ProposalApproved(uint256 indexed id, address indexed signer)
ProposalExecuted(uint256 indexed id)
ProposalCancelled(uint256 indexed id)
Withdrawn(address indexed token, address indexed to, uint256 amount)
SignerAdded / SignerRemoved / OperatorAdded / OperatorRemoved
WithdrawAddressAdded / WithdrawAddressRemoved
MorphoVaultChanged(address oldVault, address newVault, uint256 migratedAssets)
TokenAllowed(address token, bool allowed)
FeeAllowed(uint24 fee, bool allowed)
Paused(address indexed by)
Unpaused()
```

## 9. View functions

- `getSigners()`, `getThreshold()`
- `totalUsdc()` = USDC idle + `IERC4626(morphoVault).convertToAssets(shares)`
- `getBalances()` → `(usdcIdle, usdcInMorpho, address[] tokens, uint256[] balances)` — balance của mọi token trong whitelist (USDC, WETH, cbBTC). Không có field WETH/cbBTC riêng vì contract không lưu địa chỉ đó dưới dạng immutable; chỉ đọc token đã whitelist (bất biến #12).
- `getAllowedTokens()` → danh sách token whitelist
- `getProposal(id)` → type, data, số vote hợp lệ hiện tại, threshold, executed, cancelled, expired

---

## 10. Bất biến bảo mật (phải có test cho từng điều)

1. Operator **không thể** làm token rời contract, ngoại trừ: tokenIn đi vào router trong swap, USDC đi vào Morpho vault.
2. Mọi output swap và Morpho withdraw **luôn về `address(this)`**.
3. Sau mỗi tx, allowance của contract cho router / Permit2 / Morpho **= 0**.
4. Token chỉ ra ngoài qua `WithdrawBatch` đã đủ vote, và chỉ về `isWithdrawAddress`.
5. Số signer **không bao giờ < 2**.
6. Vote của signer đã bị xóa không được tính.
7. Proposal hết hạn / đã execute / đã cancel không thể execute.
8. Khi `paused`, mọi hàm operator revert. 1 signer pause được ngay; unpause chỉ qua proposal.
9. Không có hàm `delegatecall`, `selfdestruct`, hay gọi địa chỉ tùy ý với calldata tùy ý.
10. Contract **từ chối ETH** (không có `receive`/`fallback` payable).
11. Chỉ USDC nạp vào được qua `depositAndSupply`. Mọi hàm swap/withdraw revert với token ngoài `allowedToken`.
12. Token rác bị `transfer` thẳng vào contract **không làm bất kỳ hàm nào revert hay thay đổi hành vi** (test: transfer token ERC20 giả có `transfer`/`balanceOf` revert vào contract, rồi chạy lại toàn bộ flow chính).

---

## 11. Cấu trúc project

```
dca-vault/
├── foundry.toml
├── .env.example            # BASE_RPC_URL, PRIVATE_KEY_DEPLOYER, BASESCAN_API_KEY
├── src/
│   ├── DCAVault.sol
│   └── interfaces/
│       ├── ISwapRouter02.sol
│       ├── IPermit2.sol
│       └── IUniversalRouter.sol
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

**Phase 2:**
- `swapExactInputV4` qua UniversalRouter + Permit2

**Ngoài phạm vi file này:** bot service off-chain (check điều kiện DCA, tính `amountOutMinimum` bằng QuoterV2, ký tx bằng key operator). Sẽ có spec riêng.

---

## 13. Sau khi deploy — checklist vận hành

1. Verify contract trên basescan.
2. Kiểm tra `getSigners()`, operators, withdraw addresses, tokens, fees, `morphoVault` đúng như mong muốn.
3. Nạp một ít ETH (~0.01–0.02 ETH) vào **ví operator** để trả gas.
4. Chủ dự án gọi `USDC.approve(vault, amount)` rồi `depositAndSupply(amount)` từ ví chính → kiểm tra shares trên Morpho.
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
- **Constructor yêu cầu `tokens[]` chứa USDC** (nếu không → revert `UsdcNotAllowed`); trùng token/fee → revert.
- **`WithdrawBatch`: amount = 0 bị từ chối.** Token trùng trong cùng batch được xử lý tuần tự.
- **Swap đo output bằng balance trước/sau** (không tin giá trị trả về của router) và revert `InsufficientOutput` nếu < `amountOutMinimum`. `sqrtPriceLimitX96 = 0`.
- **Bán ra USDC chỉ deposit đúng số USDC nhận được**, USDC idle có sẵn không bị đụng.
- **`ChangeMorphoVault` deposit toàn bộ USDC balance** (phần redeem + USDC idle) vào vault mới.
- **Validate 2 lần**: lúc propose (từ chối sớm) và lúc execute (state có thể đã đổi, vd. withdraw address bị xóa).
- **Signer bị xóa rồi được thêm lại**: vote cũ (`hasApproved`) của họ trên proposal còn hạn sẽ được tính lại.
- **`swapExactInputV4` Phase 1 là stub** luôn revert `NotImplemented()`; `permit2` / `universalRouter` đã là immutable.

