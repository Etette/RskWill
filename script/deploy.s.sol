// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/RskWill.sol";

contract DeployRskWill is Script {
    address constant RNS_REGISTRY_TESTNET = 0x7d284aaAc6e925AAd802A53c0c69EFE3764597B8;
    address constant SMART_WALLET_FACTORY_TESTNET = 0xCBc3BC24da96Ef5606d3801E13E1DC6E98C5c877;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // deploy
        RskWill rskWill = new RskWill(
            RNS_REGISTRY_TESTNET, 
            SMART_WALLET_FACTORY_TESTNET
        );

        vm.stopBroadcast();

        console.log("RskWill deployed to:", address(rskWill));
        console.log("  rnsRegistry   :", address(rskWill.rnsRegistry()));
        console.log("  trustedFwd    :", rskWill.trustedForwarder());
    }
}
