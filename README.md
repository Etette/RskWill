# RSK-Will

An inheritance protocol that enables anyone to pass their assets to designated beneficiaries after death without relying on any trusted third party.

RSK-Will lets anyone create an on-chain will. You deposit assets, assign beneficiaries with percentage split per beneficiary and set a window of time within which you must check in to prove you are still alive. If you stop checking in, your beneficiaries can claim the inheritance. After a short waiting period, the funds distribute automatically and permanently.

## Rules

**Owner must check in periodically.** If you interact with your will either by depositing, updating or explicitly signalling liveness, your clock resets. If you miss the window entirely, your beneficiaries can act.

**Only beneficiaries can trigger a claim.** A stranger cannot initiate the process. Only someone you named in your will can start it.

**Owner can cancel a false alarm.** If a beneficiary acts while you are still alive, you can cancel the claim. This resets your clock and returns everything to normal.

**Once the waiting period after a claim expires, no one can stop distribution.** Not even the owner. The contract executes automatically and the will is permanently settled.

**Withdrawals are locked during a live claim.** You cannot drain your will after a beneficiary has initiated. Funds are frozen until the claim is either cancelled or distributed.

**Every asset distributes independently.** Each token you deposit has its own beneficiary list and percentage split. A problem with one asset never blocks another from distributing.


## Why use Rsk-Will

**No trusted third parties.** There is no lawyer, oracle or admin key. The rules are enforced entirely by the Owner using time and on-chain activity.

**One contract, many users.** Anyone can create a will inside the same deployed contract. Each will is fully isolated from every other.

**Simplicity as security.** Access control comes from the state of the contract itself rather than an imported permissions framework. Every function does one thing.

**RIF Name Service support.** Beneficiaries can be identified by human-readable names like `etette.rsk` instead of raw addresses. Names are resolved once at registration time and the address is stored. The name is never consulted again after that.

**Gasless claims via RIF Relay.** A beneficiary can initiate a claim gaslessly. The RIF relayer submits the transaction on their behalf with the beneficiaries signature as prove, removing the barrier of needing gas to access what they are owed.