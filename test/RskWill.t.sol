// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/RskWill.sol";
import "../src/interfaces/IRskWill.sol";


contract MockERC20 {
    string public name = "Mock Token";
    string public symbol = "MTK";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external virtual returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient balance");
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// simulates a broken token
contract BrokenERC20 is MockERC20 {
    function transfer(address, uint256) external pure override returns (bool) {
        return false;
    }
}

// RNS registry + resolver mocks
contract MockRNSResolver {
    mapping(bytes32 => address) private _addresses;

    function setAddr(bytes32 nameHash, address resolved) external {
        _addresses[nameHash] = resolved;
    }

    function addr(bytes32 nameHash) external view returns (address) {
        return _addresses[nameHash];
    }
}

contract MockRNSRegistry {
    MockRNSResolver public resolver_;

    constructor() {
        resolver_ = new MockRNSResolver();
    }

    // IRNSRegistry
    function resolver(bytes32) external view returns (address) {
        return address(resolver_);
    }
}

contract MockForwarder {
    function forward(address target, address originalSender, bytes calldata data)
        external
        returns (bool, bytes memory)
    {
        // ERC-2771 convention
        bytes memory payload = abi.encodePacked(data, originalSender);
        return target.call(payload);
    }
}

contract ReentrantBeneficiary {
    RskWill public will;
    address public willOwner;
    bool public attacked;

    constructor(RskWill _will, address _owner) {
        will = _will;
        willOwner = _owner;
    }

    receive() external payable {
        if (!attacked) {
            attacked = true;
            try will.distributeFunds(willOwner) {} catch {}
        }
    }
}


contract RskWillTest is Test {
    // Deployed contracts
    RskWill public rskWill;
    MockERC20 public rifToken;
    MockERC20 public tokenB;
    BrokenERC20 public brokenToken;
    MockRNSRegistry public rnsRegistry;
    MockForwarder public forwarder;


    address public owner = makeAddr("owner");
    // beneficiaries
    address public etette = makeAddr("etette"); 
    address public sabak = makeAddr("sabak"); 
    address public carol = makeAddr("carol");
    // not a beneficiary 
    address public luke = makeAddr("luke");

    uint256 public constant HEARTBEAT = 30 days;
    uint256 public constant COOLDOWN = 7 days;

    function setUp() public {
        rnsRegistry = new MockRNSRegistry();
        forwarder = new MockForwarder();
        rskWill = new RskWill(address(rnsRegistry), address(forwarder));

        rifToken = new MockERC20();
        tokenB = new MockERC20();
        brokenToken = new BrokenERC20();
        vm.deal(owner, 100 ether);
        rifToken.mint(owner, 1_000 ether);
        tokenB.mint(owner, 1_000 ether);
        brokenToken.mint(owner, 1_000 ether);
    }

    // helpers
    function _createAndFundWill() internal {
        vm.startPrank(owner);

        rskWill.createWill(HEARTBEAT, COOLDOWN);

        // rBTC allocation
        address[] memory bens = new address[](2);
        uint256[] memory bps = new uint256[](2);
        bens[0] = etette;
        bps[0] = 6_000;
        bens[1] = sabak;
        bps[1] = 4_000;
        rskWill.configureAsset(address(0), bens, bps);

        rskWill.depositRBTC{value: 10 ether}();

        // RIF token allocation
        rifToken.approve(address(rskWill), type(uint256).max);
        rskWill.configureAsset(address(rifToken), bens, bps);
        rskWill.depositToken(address(rifToken), 100 ether);

        vm.stopPrank();
    }

    function _lapseAndClaim() internal {
        skip(HEARTBEAT + 1);
        vm.prank(etette);
        rskWill.initiateClaim(owner);
    }

    function test_deploy_storesRnsAndForwarder() public view {
        assertEq(address(rskWill.rnsRegistry()), address(rnsRegistry));
        assertEq(rskWill.trustedForwarder(), address(forwarder));
    }

    function test_deploy_revertsOnZeroRns() public {
        vm.expectRevert(IRskWill.ZeroAddress.selector);
        new RskWill(address(0), address(forwarder));
    }

    function test_deploy_revertsOnZeroForwarder() public {
        vm.expectRevert(IRskWill.ZeroAddress.selector);
        new RskWill(address(rnsRegistry), address(0));
    }

    function test_createWill_setsStateToActive() public {
        vm.prank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        assertEq(uint256(rskWill.willState(owner)), uint256(RskWill.WillState.ACTIVE));
    }

    function test_createWill_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit IRskWill.WillCreated(owner, HEARTBEAT, COOLDOWN);
        vm.prank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
    }

    function test_createWill_setsLastAlive() public {
        uint256 before = block.timestamp;
        vm.prank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        assertEq(rskWill.claimableAfter(owner), before + HEARTBEAT);
    }

    function test_createWill_revertsIfAlreadyExists() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        vm.expectRevert(IRskWill.WillAlreadyExists.selector);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        vm.stopPrank();
    }

    function test_createWill_revertsOnShortHeartbeat() public {
        vm.expectRevert(IRskWill.BelowMinimumHeartbeat.selector);
        vm.prank(owner);
        rskWill.createWill(1 days, COOLDOWN);
    }

    function test_createWill_revertsOnShortCooldown() public {
        vm.expectRevert(IRskWill.BelowMinimumCooldown.selector);
        vm.prank(owner);
        rskWill.createWill(HEARTBEAT, 1 days);
    }

    function test_createWill_multipleOwnersAreIndependent() public {
        address owner2 = makeAddr("owner2");
        vm.deal(owner2, 10 ether);

        vm.prank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);

        vm.prank(owner2);
        rskWill.createWill(60 days, 14 days);

        assertEq(uint256(rskWill.willState(owner)), uint256(RskWill.WillState.ACTIVE));
        assertEq(uint256(rskWill.willState(owner2)), uint256(RskWill.WillState.ACTIVE));
    }

    function test_depositRBTC_increasesBalance() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        rskWill.depositRBTC{value: 5 ether}();
        vm.stopPrank();

        assertEq(rskWill.rbtcBalance(owner), 5 ether);
    }

    function test_depositRBTC_emitsEvent() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        vm.expectEmit(true, true, false, true);
        emit IRskWill.Deposited(owner, address(0), 3 ether);
        rskWill.depositRBTC{value: 3 ether}();
        vm.stopPrank();
    }

    function test_depositRBTC_resetsHeartbeat() public {
        vm.prank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);

        skip(20 days);

        vm.prank(owner);
        rskWill.depositRBTC{value: 1 ether}();
        assertFalse(rskWill.heartbeatLapsed(owner));
    }

    function test_depositRBTC_revertsOnZeroValue() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        vm.expectRevert(IRskWill.ZeroAmount.selector);
        rskWill.depositRBTC{value: 0}();
        vm.stopPrank();
    }

    function test_depositRBTC_revertsWhenClaiming() public {
        _createAndFundWill();
        _lapseAndClaim();

        vm.expectRevert(IRskWill.WillNotActive.selector);
        vm.prank(owner);
        rskWill.depositRBTC{value: 1 ether}();
    }

    function test_depositToken_increasesBalance() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        rifToken.approve(address(rskWill), 50 ether);
        rskWill.depositToken(address(rifToken), 50 ether);
        vm.stopPrank();

        assertEq(rskWill.tokenBalance(owner, address(rifToken)), 50 ether);
    }

    function test_depositToken_revertsOnZeroAddress() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        vm.expectRevert(IRskWill.ZeroAddress.selector);
        rskWill.depositToken(address(0), 10 ether);
        vm.stopPrank();
    }

    function test_depositToken_revertsOnZeroAmount() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        rifToken.approve(address(rskWill), 50 ether);
        vm.expectRevert(IRskWill.ZeroAmount.selector);
        rskWill.depositToken(address(rifToken), 0);
        vm.stopPrank();
    }

    function test_depositToken_revertsWithoutApproval() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        vm.expectRevert("insufficient allowance");
        rskWill.depositToken(address(rifToken), 10 ether);
        vm.stopPrank();
    }

    function test_withdrawRBTC_reducesBalance() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        rskWill.depositRBTC{value: 5 ether}();
        rskWill.withdrawRBTC(2 ether);
        vm.stopPrank();

        assertEq(rskWill.rbtcBalance(owner), 3 ether);
    }

    function test_withdrawRBTC_sendsEtherToOwner() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        rskWill.depositRBTC{value: 5 ether}();

        uint256 before = owner.balance;
        rskWill.withdrawRBTC(2 ether);
        vm.stopPrank();

        assertEq(owner.balance, before + 2 ether);
    }

    function test_withdrawRBTC_revertsOnInsufficientBalance() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        rskWill.depositRBTC{value: 1 ether}();
        vm.expectRevert(IRskWill.InsufficientBalance.selector);
        rskWill.withdrawRBTC(2 ether);
        vm.stopPrank();
    }

    function test_withdrawRBTC_lockedDuringClaiming() public {
        _createAndFundWill();
        _lapseAndClaim();

        vm.expectRevert(IRskWill.WillNotActive.selector);
        vm.prank(owner);
        rskWill.withdrawRBTC(1 ether);
    }

    function test_withdrawToken_reducesBalance() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        rifToken.approve(address(rskWill), 100 ether);
        rskWill.depositToken(address(rifToken), 100 ether);
        rskWill.withdrawToken(address(rifToken), 40 ether);
        vm.stopPrank();

        assertEq(rskWill.tokenBalance(owner, address(rifToken)), 60 ether);
    }

    function test_withdrawToken_returnsTokensToOwner() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        rifToken.approve(address(rskWill), 100 ether);
        rskWill.depositToken(address(rifToken), 100 ether);

        uint256 before = rifToken.balanceOf(owner);
        rskWill.withdrawToken(address(rifToken), 40 ether);
        vm.stopPrank();

        assertEq(rifToken.balanceOf(owner), before + 40 ether);
    }

    function test_withdrawToken_lockedDuringClaiming() public {
        _createAndFundWill();
        _lapseAndClaim();

        vm.expectRevert(IRskWill.WillNotActive.selector);
        vm.prank(owner);
        rskWill.withdrawToken(address(rifToken), 10 ether);
    }

 
    function test_stillAlive_resetsHeartbeat() public {
        vm.prank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);

        skip(29 days);

        vm.prank(owner);
        rskWill.stillAlive(0);
        assertFalse(rskWill.heartbeatLapsed(owner));
        skip(HEARTBEAT + 1);
        assertTrue(rskWill.heartbeatLapsed(owner));
    }

    function test_stillAlive_updatesIntervalWhenProvided() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        rskWill.stillAlive(60 days);
        vm.stopPrank();
        skip(31 days);
        assertFalse(rskWill.heartbeatLapsed(owner));
    }

    function test_stillAlive_emitsHeartbeatUpdatedWhenIntervalChanges() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        vm.expectEmit(true, false, false, true);
        emit IRskWill.HeartbeatUpdated(owner, 60 days);
        rskWill.stillAlive(60 days);
        vm.stopPrank();
    }

    function test_stillAlive_doesNotEmitHeartbeatUpdatedWhenZero() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        vm.recordLogs();
        rskWill.stillAlive(0);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("HeartbeatUpdated(address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != sig, "HeartbeatUpdated should not fire");
        }
    }

    function test_stillAlive_revertsOnShortNewInterval() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        vm.expectRevert(IRskWill.BelowMinimumHeartbeat.selector);
        rskWill.stillAlive(1 days);
        vm.stopPrank();
    }

    function test_stillAlive_revertsWhenClaiming() public {
        _createAndFundWill();
        _lapseAndClaim();

        vm.expectRevert(IRskWill.WillNotActive.selector);
        vm.prank(owner);
        rskWill.stillAlive(0);
    }

    function test_heartbeatLapsed_returnsFalseBeforeInterval() public {
        vm.prank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        skip(29 days);
        assertFalse(rskWill.heartbeatLapsed(owner));
    }

    function test_heartbeatLapsed_returnsTrueAfterInterval() public {
        vm.prank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        skip(HEARTBEAT + 1);
        assertTrue(rskWill.heartbeatLapsed(owner));
    }

    function test_configureAsset_storesBeneficiaries() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);

        address[] memory bens = new address[](2);
        uint256[] memory bps = new uint256[](2);
        bens[0] = etette;
        bps[0] = 7_000;
        bens[1] = sabak;
        bps[1] = 3_000;
        rskWill.configureAsset(address(0), bens, bps);
        vm.stopPrank();

        (address[] memory wallets, uint256[] memory allocs) = rskWill.assetBeneficiaries(owner, address(0));

        assertEq(wallets.length, 2);
        assertEq(wallets[0], etette);
        assertEq(allocs[0], 7_000);
        assertEq(wallets[1], sabak);
        assertEq(allocs[1], 3_000);
    }

    function test_configureAsset_revertsOnMismatchedArrays() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);

        address[] memory bens = new address[](2);
        uint256[] memory bps = new uint256[](1);
        bens[0] = etette;
        bens[1] = sabak;
        bps[0] = 10_000;

        vm.expectRevert(IRskWill.AllocationMismatch.selector);
        rskWill.configureAsset(address(0), bens, bps);
        vm.stopPrank();
    }

    function test_configureAsset_revertsIfBpsDoNotSum() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);

        address[] memory bens = new address[](2);
        uint256[] memory bps = new uint256[](2);
        bens[0] = etette;
        bps[0] = 5_000;
        bens[1] = sabak;
        bps[1] = 4_000; // sums to 9 000

        vm.expectRevert(IRskWill.AllocationMismatch.selector);
        rskWill.configureAsset(address(0), bens, bps);
        vm.stopPrank();
    }

    function test_configureAsset_allowsReconfiguration() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);

        address[] memory bens1 = new address[](1);
        uint256[] memory bps1 = new uint256[](1);
        bens1[0] = etette;
        bps1[0] = 10_000;
        rskWill.configureAsset(address(0), bens1, bps1);
        address[] memory bens2 = new address[](1);
        uint256[] memory bps2 = new uint256[](1);
        bens2[0] = sabak;
        bps2[0] = 10_000;
        rskWill.configureAsset(address(0), bens2, bps2);
        vm.stopPrank();

        (address[] memory wallets,) = rskWill.assetBeneficiaries(owner, address(0));
        assertEq(wallets.length, 1);
        assertEq(wallets[0], sabak);
    }

    function test_configureAsset_registersAssetInList() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);

        address[] memory bens = new address[](1);
        uint256[] memory bps = new uint256[](1);
        bens[0] = etette;
        bps[0] = 10_000;
        rskWill.configureAsset(address(0), bens, bps);
        rskWill.configureAsset(address(rifToken), bens, bps);
        vm.stopPrank();

        address[] memory assets = rskWill.configuredAssets(owner);
        assertEq(assets.length, 2);
    }

    function test_addBeneficiary_rebalancesExisting() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);

        // etette at 100%
        address[] memory bens = new address[](1);
        uint256[] memory bps = new uint256[](1);
        bens[0] = etette;
        bps[0] = 10_000;
        rskWill.configureAsset(address(0), bens, bps);

        // sabak at 40%
        rskWill.addBeneficiary(address(0), sabak, 4_000);
        vm.stopPrank();

        (, uint256[] memory allocs) = rskWill.assetBeneficiaries(owner, address(0));
        uint256 total = 0;
        for (uint256 i = 0; i < allocs.length; i++) {
            total += allocs[i];
        }
        assertEq(total, 10_000);
    }

    function test_addBeneficiary_revertsIfAlreadyAdded() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);

        address[] memory bens = new address[](1);
        uint256[] memory bps = new uint256[](1);
        bens[0] = etette;
        bps[0] = 10_000;
        rskWill.configureAsset(address(0), bens, bps);

        vm.expectRevert(IRskWill.BeneficiaryAlreadyAdded.selector);
        rskWill.addBeneficiary(address(0), etette, 2_000);
        vm.stopPrank();
    }

    function test_addBeneficiary_revertsOnZeroAddress() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);

        address[] memory bens = new address[](1);
        uint256[] memory bps = new uint256[](1);
        bens[0] = etette;
        bps[0] = 10_000;
        rskWill.configureAsset(address(0), bens, bps);

        vm.expectRevert(IRskWill.ZeroAddress.selector);
        rskWill.addBeneficiary(address(0), address(0), 2_000);
        vm.stopPrank();
    }

    function test_removeBeneficiary_rebalancesRemaining() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);

        address[] memory bens = new address[](3);
        uint256[] memory bps = new uint256[](3);
        bens[0] = etette;
        bps[0] = 5_000;
        bens[1] = sabak;
        bps[1] = 3_000;
        bens[2] = carol;
        bps[2] = 2_000;
        rskWill.configureAsset(address(0), bens, bps);

        rskWill.removeBeneficiary(address(0), carol);
        vm.stopPrank();

        (, uint256[] memory allocs) = rskWill.assetBeneficiaries(owner, address(0));
        uint256 total = 0;
        for (uint256 i = 0; i < allocs.length; i++) {
            total += allocs[i];
        }
        assertEq(total, 10_000);
        assertEq(allocs.length, 2);
    }

    function test_removeBeneficiary_revertsIfNotFound() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);

        address[] memory bens = new address[](1);
        uint256[] memory bps = new uint256[](1);
        bens[0] = etette;
        bps[0] = 10_000;
        rskWill.configureAsset(address(0), bens, bps);

        vm.expectRevert(IRskWill.BeneficiaryNotFound.selector);
        rskWill.removeBeneficiary(address(0), carol);
        vm.stopPrank();
    }


    function test_addBeneficiaryByName_resolvesCorrectly() public {
        bytes32 etetteHash = keccak256("etette.rsk");
        rnsRegistry.resolver_().setAddr(etetteHash, etette);

        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);

        address[] memory bens = new address[](1);
        uint256[] memory bps = new uint256[](1);
        bens[0] = sabak;
        bps[0] = 10_000;
        rskWill.configureAsset(address(0), bens, bps);

        rskWill.addBeneficiaryByName(address(0), etetteHash, 3_000);
        vm.stopPrank();

        (address[] memory wallets,) = rskWill.assetBeneficiaries(owner, address(0));
        bool etetteFound = false;
        for (uint256 i = 0; i < wallets.length; i++) {
            if (wallets[i] == etette) etetteFound = true;
        }
        assertTrue(etetteFound);
    }

    function test_addBeneficiaryByName_revertsOnUnregisteredName() public {
        bytes32 unknownHash = keccak256("nobody.rsk");
        // resolver returns address(0) for unknown names

        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);

        address[] memory bens = new address[](1);
        uint256[] memory bps = new uint256[](1);
        bens[0] = sabak;
        bps[0] = 10_000;
        rskWill.configureAsset(address(0), bens, bps);

        vm.expectRevert(IRskWill.RNSResolutionFailed.selector);
        rskWill.addBeneficiaryByName(address(0), unknownHash, 2_000);
        vm.stopPrank();
    }

    function test_initiateClaim_flipsStateToClaiming() public {
        _createAndFundWill();
        skip(HEARTBEAT + 1);

        vm.prank(etette);
        rskWill.initiateClaim(owner);

        assertEq(uint256(rskWill.willState(owner)), uint256(RskWill.WillState.CLAIMING));
    }

    function test_initiateClaim_emitsEvent() public {
        _createAndFundWill();
        skip(HEARTBEAT + 1);

        vm.expectEmit(true, true, false, false);
        emit IRskWill.ClaimInitiated(owner, etette, block.timestamp);
        vm.prank(etette);
        rskWill.initiateClaim(owner);
    }

    function test_initiateClaim_revertsBeforeHeartbeatLapses() public {
        _createAndFundWill();
        skip(HEARTBEAT - 1);

        vm.expectRevert(IRskWill.HeartbeatStillRunning.selector);
        vm.prank(etette);
        rskWill.initiateClaim(owner);
    }

    function test_initiateClaim_revertsForluke() public {
        _createAndFundWill();
        skip(HEARTBEAT + 1);

        vm.expectRevert(IRskWill.NotABeneficiary.selector);
        vm.prank(luke);
        rskWill.initiateClaim(owner);
    }

    function test_initiateClaim_revertsIfAlreadyClaiming() public {
        _createAndFundWill();
        _lapseAndClaim();

        vm.expectRevert(IRskWill.WillNotActive.selector);
        vm.prank(sabak);
        rskWill.initiateClaim(owner);
    }

    function test_initiateClaim_anyBeneficiaryCanInitiate() public {
        _createAndFundWill();
        skip(HEARTBEAT + 1);

        // sabak
        vm.prank(sabak);
        rskWill.initiateClaim(owner);

        assertEq(uint256(rskWill.willState(owner)), uint256(RskWill.WillState.CLAIMING));
    }

    function test_cancelClaim_restoresActiveState() public {
        _createAndFundWill();
        _lapseAndClaim();

        vm.prank(owner);
        rskWill.cancelClaim();

        assertEq(uint256(rskWill.willState(owner)), uint256(RskWill.WillState.ACTIVE));
    }

    function test_cancelClaim_resetsHeartbeatFully() public {
        _createAndFundWill();
        _lapseAndClaim();

        vm.prank(owner);
        rskWill.cancelClaim();
        vm.expectRevert(IRskWill.HeartbeatStillRunning.selector);
        vm.prank(etette);
        rskWill.initiateClaim(owner);
    }

    function test_cancelClaim_emitsEvent() public {
        _createAndFundWill();
        _lapseAndClaim();

        vm.expectEmit(true, false, false, false);
        emit IRskWill.ClaimCancelled(owner);
        vm.prank(owner);
        rskWill.cancelClaim();
    }

    function test_cancelClaim_revertsWhenNotClaiming() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        vm.expectRevert(IRskWill.WillNotClaiming.selector);
        rskWill.cancelClaim();
        vm.stopPrank();
    }

    function test_cancelClaim_revertsForluke() public {
        _createAndFundWill();
        _lapseAndClaim();

        vm.expectRevert(IRskWill.WillDoesNotExist.selector);
        vm.prank(luke);
        rskWill.cancelClaim();
    }

    function test_cancelClaim_allowsNewClaimAfterHeartbeatLapsesAgain() public {
        _createAndFundWill();
        _lapseAndClaim();

        vm.prank(owner);
        rskWill.cancelClaim();
        skip(HEARTBEAT + 1);
        vm.prank(etette);
        rskWill.initiateClaim(owner);

        assertEq(uint256(rskWill.willState(owner)), uint256(RskWill.WillState.CLAIMING));
    }

    function test_distributeFunds_sendsRBTCToBeneficiaries() public {
        _createAndFundWill();
        _lapseAndClaim();
        skip(COOLDOWN + 1);

        uint256 etetteBefore = etette.balance;
        uint256 sabakBefore = sabak.balance;

        rskWill.distributeFunds(owner);

        // etette 60%, sabak 40% 
        assertEq(etette.balance - etetteBefore, 6 ether);
        assertEq(sabak.balance - sabakBefore, 4 ether);
    }

    function test_distributeFunds_sendsTokensToBeneficiaries() public {
        _createAndFundWill();
        _lapseAndClaim();
        skip(COOLDOWN + 1);

        rskWill.distributeFunds(owner);
        assertEq(rifToken.balanceOf(etette), 60 ether);
        assertEq(rifToken.balanceOf(sabak), 40 ether);
    }

    function test_distributeFunds_setsStateToSettled() public {
        _createAndFundWill();
        _lapseAndClaim();
        skip(COOLDOWN + 1);

        rskWill.distributeFunds(owner);

        assertEq(uint256(rskWill.willState(owner)), uint256(RskWill.WillState.SETTLED));
    }

    function test_distributeFunds_zeroesFundBalances() public {
        _createAndFundWill();
        _lapseAndClaim();
        skip(COOLDOWN + 1);

        rskWill.distributeFunds(owner);

        assertEq(rskWill.rbtcBalance(owner), 0);
        assertEq(rskWill.tokenBalance(owner, address(rifToken)), 0);
    }

    function test_distributeFunds_revertsBeforeCooldown() public {
        _createAndFundWill();
        _lapseAndClaim();
        skip(COOLDOWN - 1);

        vm.expectRevert(IRskWill.CooldownNotOver.selector);
        rskWill.distributeFunds(owner);
    }

    function test_distributeFunds_revertsIfNotClaiming() public {
        _createAndFundWill();

        vm.expectRevert(IRskWill.WillNotClaiming.selector);
        rskWill.distributeFunds(owner);
    }

    function test_distributeFunds_canBeCalledByAnyone() public {
        _createAndFundWill();
        _lapseAndClaim();
        skip(COOLDOWN + 1);

        // anyone can trigger distribute
        vm.prank(luke);
        rskWill.distributeFunds(owner);

        assertEq(uint256(rskWill.willState(owner)), uint256(RskWill.WillState.SETTLED));
    }

    function test_distributeFunds_revertsAfterSettled() public {
        _createAndFundWill();
        _lapseAndClaim();
        skip(COOLDOWN + 1);

        rskWill.distributeFunds(owner);

        vm.expectRevert(IRskWill.WillNotClaiming.selector);
        rskWill.distributeFunds(owner);
    }

    function test_distributeFunds_multipleAssetsInOneTx() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);

        address[] memory bens = new address[](2);
        uint256[] memory bps = new uint256[](2);
        bens[0] = etette;
        bps[0] = 5_000;
        bens[1] = sabak;
        bps[1] = 5_000;

        rskWill.configureAsset(address(0), bens, bps);
        rskWill.configureAsset(address(rifToken), bens, bps);
        rskWill.configureAsset(address(tokenB), bens, bps);

        rskWill.depositRBTC{value: 10 ether}();

        rifToken.approve(address(rskWill), 200 ether);
        rskWill.depositToken(address(rifToken), 200 ether);

        tokenB.approve(address(rskWill), 400 ether);
        rskWill.depositToken(address(tokenB), 400 ether);
        vm.stopPrank();

        skip(HEARTBEAT + 1);
        vm.prank(etette);
        rskWill.initiateClaim(owner);

        skip(COOLDOWN + 1);
        rskWill.distributeFunds(owner);

        assertEq(etette.balance, 5 ether);
        assertEq(rifToken.balanceOf(etette), 100 ether);
        assertEq(tokenB.balanceOf(etette), 200 ether);
    }

    function test_distributeFunds_lastBeneficiaryReceivesRemainder() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);

        address[] memory bens = new address[](3);
        uint256[] memory bps = new uint256[](3);
        bens[0] = etette;
        bps[0] = 3_333;
        bens[1] = sabak;
        bps[1] = 3_333;
        bens[2] = carol;
        bps[2] = 3_334;
        rskWill.configureAsset(address(0), bens, bps);
        rskWill.depositRBTC{value: 10 ether}();
        vm.stopPrank();

        skip(HEARTBEAT + 1);
        vm.prank(etette);
        rskWill.initiateClaim(owner);
        skip(COOLDOWN + 1);
        rskWill.distributeFunds(owner);
        uint256 totalSent = etette.balance + sabak.balance + carol.balance;
        assertEq(totalSent, 10 ether);
        assertEq(rskWill.rbtcBalance(owner), 0);
    }

    function test_brokenToken_doesNotBlockDistribution() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);

        address[] memory bens = new address[](2);
        uint256[] memory bps = new uint256[](2);
        bens[0] = etette;
        bps[0] = 5_000;
        bens[1] = sabak;
        bps[1] = 5_000;

        rskWill.configureAsset(address(0), bens, bps);
        rskWill.configureAsset(address(brokenToken), bens, bps);

        rskWill.depositRBTC{value: 10 ether}();

        brokenToken.approve(address(rskWill), 100 ether);
        rskWill.depositToken(address(brokenToken), 100 ether);
        vm.stopPrank();

        skip(HEARTBEAT + 1);
        vm.prank(etette);
        rskWill.initiateClaim(owner);
        skip(COOLDOWN + 1);
        rskWill.distributeFunds(owner);
        assertEq(etette.balance, 5 ether);
        assertEq(sabak.balance, 5 ether);
        assertEq(uint256(rskWill.willState(owner)), uint256(RskWill.WillState.SETTLED));
    }

    function test_distributeFunds_blocksReentrancy() public {
        ReentrantBeneficiary reentrant = new ReentrantBeneficiary(rskWill, owner);

        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);

        address[] memory bens = new address[](2);
        uint256[] memory bps = new uint256[](2);
        bens[0] = address(reentrant);
        bps[0] = 5_000;
        bens[1] = sabak;
        bps[1] = 5_000;

        rskWill.configureAsset(address(0), bens, bps);
        rskWill.depositRBTC{value: 10 ether}();
        vm.stopPrank();

        skip(HEARTBEAT + 1);
        vm.prank(sabak);
        rskWill.initiateClaim(owner);
        skip(COOLDOWN + 1);
        rskWill.distributeFunds(owner);
        assertTrue(reentrant.attacked());
        assertEq(uint256(rskWill.willState(owner)), uint256(RskWill.WillState.SETTLED));
    }

    function test_rifRelay_beneficiaryCanInitiateClaimWithoutGas() public {
        _createAndFundWill();
        skip(HEARTBEAT + 1);
        bytes memory callData = abi.encodeWithSelector(RskWill.initiateClaim.selector, owner);
        (bool success,) = forwarder.forward(address(rskWill), etette, callData);
        assertTrue(success);

        assertEq(uint256(rskWill.willState(owner)), uint256(RskWill.WillState.CLAIMING));
    }

    function test_rifRelay_lukeCannotImpersonateBeneficiary() public {
        _createAndFundWill();
        skip(HEARTBEAT + 1);

        bytes memory callData = abi.encodeWithSelector(RskWill.initiateClaim.selector, owner);
        (bool success, bytes memory returnData) = forwarder.forward(address(rskWill), luke, callData);
        assertFalse(success);
        bytes4 selector;
        assembly {
            selector := mload(add(returnData, 32))
        }
        assertEq(selector, IRskWill.NotABeneficiary.selector);
    }

    function test_claimableAfter_returnsCorrectTimestamp() public {
        uint256 ts = block.timestamp;
        vm.prank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);
        assertEq(rskWill.claimableAfter(owner), ts + HEARTBEAT);
    }

    function test_distributableAfter_returnsZeroWhenNotClaiming() public {
        _createAndFundWill();
        assertEq(rskWill.distributableAfter(owner), 0);
    }

    function test_distributableAfter_returnsCorrectTimestampWhenClaiming() public {
        _createAndFundWill();
        _lapseAndClaim();
        uint256 expected = block.timestamp + COOLDOWN;
        assertEq(rskWill.distributableAfter(owner), expected);
    }

    function test_configuredAssets_returnsAllAssets() public {
        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);

        address[] memory bens = new address[](1);
        uint256[] memory bps = new uint256[](1);
        bens[0] = etette;
        bps[0] = 10_000;

        rskWill.configureAsset(address(0), bens, bps);
        rskWill.configureAsset(address(rifToken), bens, bps);
        rskWill.configureAsset(address(tokenB), bens, bps);
        vm.stopPrank();

        address[] memory assets = rskWill.configuredAssets(owner);
        assertEq(assets.length, 3);
    }

    function testFuzz_allocationAlwaysSumsToTotalBps(uint16 etetteBps, uint16 sabakBps) public {
        etetteBps = uint16(bound(etetteBps, 1_000, 9_000));
        sabakBps = uint16(10_000 - etetteBps);

        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);

        address[] memory bens = new address[](2);
        uint256[] memory bps = new uint256[](2);
        bens[0] = etette;
        bps[0] = etetteBps;
        bens[1] = sabak;
        bps[1] = sabakBps;
        rskWill.configureAsset(address(0), bens, bps);
        rskWill.removeBeneficiary(address(0), etette);
        vm.stopPrank();

        (, uint256[] memory allocs) = rskWill.assetBeneficiaries(owner, address(0));
        uint256 total = 0;
        for (uint256 i = 0; i < allocs.length; i++) {
            total += allocs[i];
        }
        assertEq(total, 10_000);
    }

    function testFuzz_distributionNeverExceedsDeposit(uint96 depositAmount) public {
        depositAmount = uint96(bound(depositAmount, 1 ether, 50 ether));
        vm.deal(owner, depositAmount + 1 ether);

        vm.startPrank(owner);
        rskWill.createWill(HEARTBEAT, COOLDOWN);

        address[] memory bens = new address[](2);
        uint256[] memory bps = new uint256[](2);
        bens[0] = etette;
        bps[0] = 6_000;
        bens[1] = sabak;
        bps[1] = 4_000;
        rskWill.configureAsset(address(0), bens, bps);
        rskWill.depositRBTC{value: depositAmount}();
        vm.stopPrank();

        uint256 etetteBefore = etette.balance;
        uint256 sabakBefore = sabak.balance;

        skip(HEARTBEAT + 1);
        vm.prank(etette);
        rskWill.initiateClaim(owner);
        skip(COOLDOWN + 1);
        rskWill.distributeFunds(owner);

        uint256 totalSent = (etette.balance - etetteBefore) + (sabak.balance - sabakBefore);
        assertEq(totalSent, depositAmount);
    }
}
