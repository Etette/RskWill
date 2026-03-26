# RSK-Will

An inheritance protocol that enables anyone to pass their on-chain assets to designated beneficiaries after death, without relying on any trusted third party.

RSK-Will lets anyone create a Will directly on the Rootstock blockchain. You deposit assets, assign beneficiaries with a percentage split per asset and set a window of time within which you must check in to prove you are still alive. If you stop checking in, your beneficiaries can claim the inheritance. After a short waiting period, the funds distribute automatically and permanently.

---

## What it does

When you create a Will, you configure three things: the assets you want to leave behind, who receives them and in what proportion and how long you are allowed to go silent before your beneficiaries can act.

From that point, the contract runs itself. Every time you interact with your Will either by depositing funds, updating beneficiaries or simply checking in, your silence clock resets. If you miss your window entirely, any named beneficiary can initiate a claim. The contract then enters a waiting period during which you can cancel if you are still alive. If nothing happens, the funds distribute automatically once the waiting period ends. The Will is then permanently settled and cannot be reopened.

Each asset you deposit is managed independently. You can leave rBTC to one set of people, RIF tokens to another and any other token to a third group each with its own percentage split summing to one hundred percent.

---

## Rules it enforces

**You must check in periodically.**
Any interaction with your Will counts as proof of life. Depositing, withdrawing, updating beneficiaries or calling the check-in function directly. Each action resets your silence window. If you miss the window entirely and a beneficiary initiates a claim, the process begins.

**Only your named beneficiaries can trigger a claim.**
No stranger, third party or automated system can start the inheritance process. Only an address you explicitly registered as a beneficiary has the right to initiate.

**You can cancel a false alarm while you are still alive.**
If a beneficiary initiates a claim while you are still alive perhaps because you forgot to check in, you can cancel it. Cancellation immediately resets your silence clock to a full window, so beneficiaries cannot initiate again straight away.

**Once the waiting period expires, distribution is automatic and final.**
After a claim is initiated, there is a mandatory waiting period to give you time to cancel. If that period passes without a cancellation, anyone can trigger the distribution. At that point the owner cannot intervene. Funds go out and the Will is settled permanently.

**Withdrawals are locked during an active claim.**
From the moment a beneficiary initiates a claim until it is either cancelled or distributed, you cannot move funds out of the contract. This prevents a last-minute drain that would leave beneficiaries with nothing.

**Each asset distributes independently.**
A failed or broken token transfer for one asset does not block any other asset from distributing. Every token has its own beneficiary list, its own percentage split and its own transfer path.

**Percentage splits must always total one hundred percent.**
When you add or remove a beneficiary from an asset, the remaining allocations are automatically rebalanced proportionally. Any rounding difference goes to the beneficiary with the largest share.

---

## Design choices and the reasoning behind them

**No trusted third parties.**
There is no lawyer, oracle, admin key or off-chain process involved at any point. The rules are enforced entirely by the contract using time and on-chain activity. Either you interacted with the contract or you did not. There is nothing in between to corrupt, delay or fail.

**One contract, many users.**
Anyone can create a Will inside the same deployed contract without needing to deploy their own. Each Will is completely isolated. Balances, beneficiaries, state and timing never touch each other. This makes the protocol accessible without requiring any deployment knowledge.

**Roles derived from state, not a permissions registry.**
There is no access control library or role assignment system. Who can do what is determined entirely by the current state of each Will. If your Will is active, you can deposit and update. If a claim is live, only you can cancel it. If the Will is settled, nobody can do anything. This approach means less code, fewer moving parts and a smaller surface for mistakes.

**Simplicity as security.**
Every function does exactly one thing. Error messages are plain sentences. Variable names are full words. The most catastrophic failures in smart contract history happened in code that was trying to be clever. RSK-Will deliberately avoids cleverness. If a reader cannot understand what a function does in under thirty seconds, that is a bug in the design.

**Assets are independent by design.**
Rather than pooling all assets into one distribution pass, each token is configured, deposited and distributed on its own. This means a token with a broken transfer implementation cannot freeze the entire Will. rBTC always distributes regardless of what any ERC20 token does.

**RIF Name Service for human-readable beneficiaries.**
Beneficiaries can be registered using a `.rsk` name like `etette.rsk` instead of a raw address. The name is resolved to an address exactly once at registration time and that address is stored permanently. The name is never consulted again. This means the Will is not affected if the name later changes ownership and there is no ongoing dependency on the name service after setup.

**Gasless claim initiation via RIF Relay.**
A beneficiary who has never held cryptocurrency should still be able to act when the time comes. RIF Relay allows a third-party relayer to submit the `initiateClaim` transaction on behalf of the beneficiary using their cryptographic signature as proof of intent. The beneficiary never needs to acquire gas. This removes the most practical barrier between a named heir and what they are owed.

---

## Contract addresses

| Network | Contract | Address |
|---|---|---|
| RSK Testnet | RNS Registry | `0x7d284aaac6e925aad802a53c0c69efe3764597b8` |
| RSK Testnet | RIF Token | `0x19f64674d8a5b4e652319f5e239efd3bc969a1fe` |
| RSK Testnet | RIF Relay Hub | `0xAd525463961399793f8716b0D85133ff7503a7C2` |
| RSK Mainnet | RNS Registry | `0xcb868aeabd31e2b66f74e9a55cf064abb31a4ad5` |
| RSK Mainnet | RIF Token | `0x2acc95758f8b5f583470ba265eb685a8f45fc9d5` |
| RSK Mainnet | RIF Relay Hub | `0x438Ce7f1FEC910588Be0fa0fAcD27D82De1DE0bC` |

---

## Running the project

**Tests**
```bash
forge test -vv
```

**Local deployment and workflow**
```bash
anvil &
forge script script/RskWill.s.sol:RskWillScript \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast --skip-simulation -vv
```

**Forked RSK testnet workflow**
```bash
anvil --fork-url https://public-node.testnet.rsk.co --chain-id 31 &
forge script script/RskWillFork.s.sol:RskWillForkScript \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast --skip-simulation --legacy -vv
```