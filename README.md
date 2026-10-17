# Squeek (SQUEEK)

A plain, fixed-supply ERC-20 token for the IdentityMD custom-token launch on Ethereum (chain id 1).

| Parameter        | Value                                                   |
| ---------------- | ------------------------------------------------------- |
| Solidity contract | `SqueekToken` (`src/SqueekToken.sol`)                  |
| `name()`         | `Squeek`                                                |
| `symbol()`       | `SQUEEK`                                                |
| `decimals()`     | `18`                                                    |
| `totalSupply()`  | `1000000000000000000000000000` (1,000,000,000 × 10^18)  |
| Constructor args | none                                                    |
| Mint             | once, in the constructor, the whole supply to `msg.sender` |
| Admin roles      | none                                                    |

## What the contract does

`SqueekToken` inherits OpenZeppelin `ERC20` v5.4.0 and adds nothing but constants and the one-time
mint. On deployment it mints `TOTAL_SUPPLY` to the deployer, which at the IdentityMD launch is the
`ProjectFactory`. After that:

- `totalSupply()` is constant. There is no mint, burn, `burnFrom`, issue or rebase path, for anyone.
- Transfers and `transferFrom` move exactly the amount requested. There is no fee, tax, reflection,
  burn-on-transfer, cooldown, max-wallet or max-transaction rule, so the launch flows (factory to
  MerkleDistributor, distributor to claimants, factory to the Uniswap v4 PoolManager, pool swaps in
  either direction) arrive whole without any exemption list.
- There is no owner, pauser, blacklist, freeze, seize or upgrade function. Nobody can move or lock a
  holder's balance except through that holder's own `transfer` or an allowance they granted.
- The contract has no constructor arguments, no external calls, no `delegatecall`, no `selfdestruct`
  and no library calls that leave link placeholders. The creation code is fully determined by the
  source and the pinned compiler.
- Approvals follow the ERC-20 standard as OpenZeppelin implements it: `approve` overwrites,
  `transferFrom` decrements a finite allowance and leaves `type(uint256).max` untouched. There is no
  `increaseAllowance`/`decreaseAllowance` pair (removed in OZ v5) and no EIP-2612 `permit`, since the
  brief did not ask for either.

## Assumptions

- The brief asked for a token with a name, symbol and fixed supply and no other behaviour. No
  governance, vesting, tax or burn mechanics were added.
- "Deployer" means the account that executes the creation transaction (`msg.sender` of the
  constructor). On the launch that is the factory, which then distributes the supply per the launch
  economics. Nothing in the contract depends on who that is.
- Ethereum mainnet is the target; nothing is chain-specific. `evm_version = "cancun"` is set in
  `foundry.toml`, which mainnet supports.

## Deployment parameters

The token takes **no constructor arguments**. The launch manifest step records it as:

- `token.contract`: `SqueekToken`
- `token.name`: `Squeek`
- `token.symbol`: `SQUEEK`
- `token.decimals`: `18`
- `token.totalSupply`: `1000000000000000000000000000`
- `token.constructorArgs`: `[]`

Launch economics, pool settings (pair IMD, fee 12500, tick spacing 60) and the swarm share are the
launch's and are written by the manifest step, not by this repository. No `launch.json` is included
here on purpose.

`script/DeploySqueekToken.s.sol` is a reviewable script for test networks. Its `deploy()` function is
the whole procedure and is exercised directly by the tests. `run()` wraps it in a broadcast with the
signer forge is given on the command line. The IdentityMD launch does not use this script.

## Operational responsibilities

There is nothing to configure or administer after launch. The contract has no settings, so there is
no "After launch" list of owner setters.

What remains operationally:

- **Supply custody.** Whoever deploys holds the entire supply until they move it. At the launch this
  is the factory, which forwards the swarm share, seeds the pool and sends the remainder to the
  requester's `remainderTo` address in the same launch transaction.
- **Irreversibility.** With no admin role, no mistake can be corrected on-chain after deployment:
  no pause, no recovery of tokens sent to the wrong address, no change to name or symbol. Review the
  source before launch; that is the only control point.
- **Explorer verification.** Source verification on Etherscan belongs to the network's deployer
  after the launch. Build settings to reproduce the bytecode: solc 0.8.26, optimizer on with 200
  runs, `bytecode_hash = "none"`, `cbor_metadata = false`, EVM version cancun.
- **Approvals.** Holders are responsible for the allowances they grant. Infinite approvals are not
  decremented and should be given only to contracts the holder trusts.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, sets `bytecode_hash = "none"`, disables `ffi` and grants no
filesystem permissions. Tests read no environment variables and pass in any order and in parallel.
The verifier's fuzz seed (`FOUNDRY_FUZZ_SEED=0x1dbf84e3…`) was used locally as well.

### Test coverage

- Metadata: name, symbol, decimals, supply constant.
- Constructor: whole supply minted once to the deployer (EOA and contract deployer), single
  `Transfer` from the zero address, independent deployments.
- Transfers: exact amounts, events, whole balance, zero amount, self-transfer, the launch flow
  (factory → distributor → claimant) arriving whole.
- Failure paths: insufficient balance, empty account, zero-address recipient, more than supply,
  zero spender, missing or insufficient allowance, owner balance too low, deployer cannot pull from a
  holder without approval.
- No privileged surface: eighteen common admin selectors (mint, burn, pause, blacklist, freeze,
  ownership, upgrade) all revert from both the deployer and a stranger; plain ether and unknown
  selectors are rejected; runtime bytecode contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`
  and is under the EIP-170 limit.
- Deploy script: `deploy()` mints to its caller.
- Fuzz: transfer conservation of supply, over-balance reverts, allowance enforcement, chained
  transfers.

## Dependencies

Vendored as ordinary files under `lib/` (no git submodules):

- `lib/forge-std` — forge-std v1.11.0 (MIT / Apache-2.0), tests only.
- `lib/openzeppelin-contracts` — OpenZeppelin Contracts v5.4.0 (MIT). Only `ERC20`, its
  interfaces and `Context` are compiled into the token.

## Security notes

Tests passing are not an audit. The token's attack surface is that of OpenZeppelin's audited `ERC20`
with no additions, but an independent adversarial review before release remains the launch policy's
responsibility. The pre-deploy items that need a live deployment (explorer verification) are the
network deployer's. Tools run for this work: `forge build`, `forge test` (including fuzz with the
verifier's seed) and `forge fmt --check`. Slither and Mythril were not available in this environment.
