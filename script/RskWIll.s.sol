// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/RskWill.sol";


contract RskWillForkScript is Script {
    address constant RNS_REGISTRY_MAINNET = 0xCb868Aeabd31E2b66F74E9a55Cf064aBB31a4ad5;
    address constant RNS_REGISTRY_TESTNET = 0x7d284aaAc6e925AAd802A53c0c69EFE3764597B8;
    address constant RELAY_HUB_MAINNET = 0x438Ce7f1FEC910588Be0fa0fAcD27D82De1DE0bC;
    address constant SMART_WALLET_FACTORY_MAINNET = 0x9EEbEC6C5157bEE13b451b1dfE1eE2cB40846323;
    address constant RELAY_HUB_TESTNET = 0xAd525463961399793f8716b0D85133ff7503a7C2;
    address constant SMART_WALLET_FACTORY_TESTNET = 0xCBc3BC24da96Ef5606d3801E13E1DC6E98C5c877;
    address constant RIF_MAINNET = 0x2AcC95758f8b5F583470ba265EB685a8F45fC9D5;
    address constant RIF_TESTNET = 0x19F64674D8A5B4E652319F5e239eFd3bc969A1fE;
    uint256 constant HEARTBEAT = 30 days;
    uint256 constant COOLDOWN = 7 days;

    bool isMainnet;
    address rnsRegistry;
    address forwarderAddr;
    address rifToken;
    address relayHub;

    address owner;
    uint256 ownerKey;
    address basy;
    address mike;
    string basyRnsName;

    RskWill rskWill;
    function run() external {
        _resolveNetwork();
        _resolveActors();
        _verifyLiveContracts();
        _deployRskWill();
        _runWorkflow();
    }

    // detect network and select addresses

    function _resolveNetwork() internal {
        isMainnet = vm.envOr("FORK_MAINNET", false);

        if (isMainnet) {
            rnsRegistry = RNS_REGISTRY_MAINNET;
            forwarderAddr = SMART_WALLET_FACTORY_MAINNET;
            rifToken = RIF_MAINNET;
            relayHub = RELAY_HUB_MAINNET;
        } else {
            rnsRegistry = RNS_REGISTRY_TESTNET;
            forwarderAddr = SMART_WALLET_FACTORY_TESTNET;
            rifToken = RIF_TESTNET;
            relayHub = RELAY_HUB_TESTNET;
        }

        console.log("=== RSK-Will Fork Script ===");
        console.log("Network       :", isMainnet ? "RSK Mainnet" : "RSK Testnet");
        console.log("RNS Registry  :", rnsRegistry);
        console.log("Relay Hub     :", relayHub);
        console.log("SmartWallet F.:", forwarderAddr);
        console.log("RIF Token     :", rifToken);
    }

    // resolve actors from environment
    function _resolveActors() internal {
        ownerKey = vm.envOr("OWNER_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        owner = vm.addr(ownerKey);

        basy = vm.envOr("basy", address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8));
        mike = vm.envOr("mike", address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC));
        basyRnsName = "bitcoin.rsk";
        if (vm.envOr("OWNER_KEY", bytes32(0)) == bytes32(0)) {
            vm.deal(owner, 10 ether);
            console.log("  vm.deal: funded owner with 10 rBTC (local fork mode)");
        }

        console.log("\nActors:");
        console.log("  Owner         :", owner);
        console.log("  basy         :", basy);
        console.log("  mike           :", mike);
        console.log("  basy RNS name:", basyRnsName);
    }

    // verify RIF contracts are live before forking and deploying against them
    function _verifyLiveContracts() internal view {
        console.log("\n[Verify] Checking contracts are live on fork...");

        require(_hasCode(rnsRegistry), "RNS Registry not live on this fork");
        console.log("  RNS Registry  : LIVE");

        require(_hasCode(relayHub), "RIF RelayHub not live on this fork");
        console.log("  RIF RelayHub  : LIVE");

        require(_hasCode(forwarderAddr), "RIF SmartWalletFactory not live on this fork");
        console.log("  SmartWalletF. : LIVE");

        require(_hasCode(rifToken), "RIF Token not live on this fork");
        console.log("  RIF Token     : LIVE");
    }
    
    // deploy
    function _deployRskWill() internal {
        console.log("\n[Deploy] Deploying RskWill with real infrastructure...");

        vm.startBroadcast(ownerKey);
        rskWill = new RskWill(rnsRegistry, forwarderAddr);
        vm.stopBroadcast();

        console.log("  RskWill       :", address(rskWill));
        console.log("  rnsRegistry   :", address(rskWill.rnsRegistry()));
        console.log("  trustedFwd    :", rskWill.trustedForwarder());
    }

    // workflow of RskWill
    function _runWorkflow() internal {
        console.log("\n[4a] Owner creates will...");
        vm.startBroadcast(ownerKey);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        vm.stopBroadcast();
        _assertState(RskWill.WillState.ACTIVE, "Should be ACTIVE");
        console.log("  State: ACTIVE");

        console.log("\n[4b] Resolving basy RNS name on real chain...");
        address basyResolved = _resolveRNS(basyRnsName);
        if (basyResolved != address(0)) {
            console.log("  RNS resolved  :", basyResolved);
            if (basyResolved != basy) {
                console.log("  Note: using RNS-resolved address for basy.");
                basy = basyResolved;
            }
        } else {
            console.log("  RNS name not registered using basy env address directly.");
            console.log("  Register at: testnet.manager.rns.rifos.org");
        }

        console.log("\n[4c] Configuring rBTC allocation (basy 60%, mike 40%)...");
        {
            address[] memory bens = new address[](2);
            uint256[] memory bps = new uint256[](2);
            bens[0] = basy;
            bps[0] = 6_000;
            bens[1] = mike;
            bps[1] = 4_000;

            vm.startBroadcast(ownerKey);
            rskWill.configureAsset(address(0), bens, bps);
            vm.stopBroadcast();
        }
        console.log("  basy: 60%  mike: 40%  (rBTC)");

        console.log("\n[4d] Configuring RIF token allocation...");
        uint256 rifBalance = IERC20(rifToken).balanceOf(owner);
        console.log("  Owner RIF balance on fork:", rifBalance / 1e18, "RIF");

        if (rifBalance == 0) {
            console.log("  No RIF balance  seeding via vm.store (works on local fork only)...");
            bytes32 balanceSlot = keccak256(abi.encode(owner, uint256(0)));
            vm.store(rifToken, balanceSlot, bytes32(uint256(500 ether)));
            rifBalance = IERC20(rifToken).balanceOf(owner);
            console.log("  Seeded RIF balance     :", rifBalance / 1e18, "RIF");
        }

        if (rifBalance > 0) {
            address[] memory bens = new address[](2);
            uint256[] memory bps = new uint256[](2);
            bens[0] = basy;
            bps[0] = 7_000;
            bens[1] = mike;
            bps[1] = 3_000;

            uint256 depositAmount = rifBalance / 10;

            vm.startBroadcast(ownerKey);
            IERC20(rifToken).approve(address(rskWill), depositAmount);
            rskWill.configureAsset(rifToken, bens, bps);
            rskWill.depositToken(rifToken, depositAmount);
            vm.stopBroadcast();

            console.log("  basy: 70%  mike: 30%  (RIF)");
            console.log("  RIF deposited:", rskWill.tokenBalance(owner, rifToken) / 1e18, "RIF");
        } else {
            console.log("  Skipping RIF deposit (no balance available).");
        }

        console.log("\n[4e] Depositing rBTC...");
        vm.startBroadcast(ownerKey);
        rskWill.depositRBTC{value: 2 ether}();
        vm.stopBroadcast();
        console.log("  rBTC deposited:", rskWill.rbtcBalance(owner) / 1e18, "rBTC");

        console.log("\n[4f] Testing addBeneficiaryByName() against real RNS...");
        string memory carolRnsName = "satoshi.rsk";
        if (bytes(carolRnsName).length > 0) {
            bytes32 carolHash = _namehashStr(carolRnsName);
            address carolResolved = _resolveRNS(carolRnsName);
            if (carolResolved != address(0)) {
                vm.startBroadcast(ownerKey);
                rskWill.addBeneficiaryByName(address(0), carolHash, 1_000);
                vm.stopBroadcast();
                console.log("  Added carol via RNS:", carolResolved);

                vm.startBroadcast(ownerKey);
                rskWill.removeBeneficiary(address(0), carolResolved);
                vm.stopBroadcast();
                console.log("  Removed carol. Rebalanced.");
            } else {
                console.log("  CAROL_RNS_NAME set but name not registered  skipping.");
            }
        } else {
            console.log("  CAROL_RNS_NAME not set  skipping.");
            console.log("  Set CAROL_RNS_NAME=<name.rsk> to test addBeneficiaryByName().");
        }

        console.log("\n[4g] Owner signals stillAlive() with 45 day interval...");
        vm.startBroadcast(ownerKey);
        rskWill.stillAlive(45 days);
        vm.stopBroadcast();
        console.log("  Claimable after:", rskWill.claimableAfter(owner));

        console.log("\n[4h] Warping time past heartbeat...");
        vm.warp(block.timestamp + 45 days + 1);
        console.log("  Heartbeat lapsed:", rskWill.heartbeatLapsed(owner) ? "YES" : "NO");

        // initiate claim
        console.log("\n[4i] basy initiates claim (direct call  no relay server on fork)...");
        vm.prank(basy);
        rskWill.initiateClaim(owner);
        _assertState(RskWill.WillState.CLAIMING, "Should be CLAIMING");
        console.log("  State: CLAIMING");
        console.log("  Distributable after:", rskWill.distributableAfter(owner));

        // cancel false alarm
        console.log("\n[4j] Owner cancels claim (false alarm)...");
        vm.startBroadcast(ownerKey);
        rskWill.cancelClaim();
        vm.stopBroadcast();
        _assertState(RskWill.WillState.ACTIVE, "Should be ACTIVE");
        console.log("  State: ACTIVE (heartbeat reset)");

        // owner demised and inactive again
        console.log("\n[4k] Owner truly silent  warp past heartbeat again...");
        vm.warp(block.timestamp + 45 days + 1);
        console.log("  Heartbeat lapsed:", rskWill.heartbeatLapsed(owner) ? "YES" : "NO");

        console.log("\n[4l] basy initiates claim again...");
        vm.prank(basy);
        rskWill.initiateClaim(owner);
        _assertState(RskWill.WillState.CLAIMING, "Should be CLAIMING");
        console.log("  State: CLAIMING");

        console.log("\n[4m] Cooldown passes. Distributing...");
        vm.warp(block.timestamp + COOLDOWN + 1);

        uint256 basyRbtcBefore = basy.balance;
        uint256 mikeRbtcBefore = mike.balance;
        uint256 basyRifBefore = IERC20(rifToken).balanceOf(basy);
        uint256 mikeRifBefore = IERC20(rifToken).balanceOf(mike);

        vm.startBroadcast(ownerKey);
        rskWill.distributeFunds(owner);
        vm.stopBroadcast();

        _assertState(RskWill.WillState.SETTLED, "Should be SETTLED");

        // final balances and state
        console.log("\n[4n] Distribution complete. Final balances:");
        console.log("  basy rBTC received:", (basy.balance - basyRbtcBefore) / 1e15, "milli-rBTC");
        console.log("  mike   rBTC received:", (mike.balance - mikeRbtcBefore) / 1e15, "milli-rBTC");
        console.log("  basy RIF  received:", (IERC20(rifToken).balanceOf(basy) - basyRifBefore) / 1e18, "RIF");
        console.log("  mike   RIF  received:", (IERC20(rifToken).balanceOf(mike) - mikeRifBefore) / 1e18, "RIF");
        console.log("  Will rBTC balance  :", rskWill.rbtcBalance(owner));
        console.log("  Will RIF  balance  :", rskWill.tokenBalance(owner, rifToken));
        console.log("  Will state         : SETTLED");
        console.log("\n=== Fork workflow complete ===");
    }

    // helpers
    function _assertState(RskWill.WillState expected, string memory message) internal view {
        require(rskWill.willState(owner) == expected, message);
    }

    function _hasCode(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    function _resolveRNS(string memory name) internal view returns (address resolved) {
        bytes32 node = _namehashStr(name);

        (bool ok1, bytes memory resolverData) =
            rnsRegistry.staticcall(abi.encodeWithSignature("resolver(bytes32)", node));
        if (!ok1 || resolverData.length < 32) return address(0);

        address resolverAddr = abi.decode(resolverData, (address));
        if (resolverAddr == address(0)) return address(0);

        (bool ok2, bytes memory addrData) = resolverAddr.staticcall(abi.encodeWithSignature("addr(bytes32)", node));
        if (!ok2 || addrData.length < 32) return address(0);

        resolved = abi.decode(addrData, (address));
    }

    /// basy.rsk → keccak256(keccak256(0, "rsk"), "basy")
    function _namehashStr(string memory name) internal pure returns (bytes32 node) {
        node = bytes32(0);
        bytes memory nameBytes = bytes(name);
        uint256 len = nameBytes.length;
        if (len == 0) return node;

        uint256 end = len;
        for (uint256 i = len; i > 0;) {
            unchecked {
                i--;
            }
            if (nameBytes[i] == "." || i == 0) {
                uint256 start = (nameBytes[i] == ".") ? i + 1 : i;
                bytes memory label = new bytes(end - start);
                for (uint256 j = start; j < end; j++) {
                    label[j - start] = nameBytes[j];
                }
                node = keccak256(abi.encodePacked(node, keccak256(label)));
                end = i;
            }
        }
    }
}
