// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IRskWill.sol";

contract RskWill is IRskWill {
    address public constant RBTC = address(0);
    //10000 bps = 100 % of owner asset
    uint256 public constant TOTAL_BPS = 10_000;
    uint256 public constant MIN_HEARTBEAT = 30 days;
    uint256 public constant MIN_COOLDOWN = 7 days;

    enum WillState {
        INACTIVE,
        ACTIVE,
        CLAIMING,
        SETTLED
    }

    struct Beneficiary {
        address wallet;
        uint256 bps;
    }

    struct AssetAllocation {
        Beneficiary[] beneficiaries;
        mapping(address => uint256) index;
    }

    struct Will {
        WillState state;
        uint256 heartbeatInterval;
        uint256 cooldownPeriod;
        uint256 lastAlive;
        uint256 claimInitiatedAt;
        address[] configuredAssets;
        mapping(address => AssetAllocation) allocations;
        uint256 rbtcBalance;
        mapping(address => uint256) tokenBalance;
    }

    mapping(address => Will) private wills;
    IRNSRegistry public immutable rnsRegistry;
    address public immutable trustedForwarder; // RIF Relay

    modifier onlyWillOwner() {
        address caller = _msgSender();
        if (wills[caller].state == WillState.INACTIVE) revert WillDoesNotExist();
        _;
    }

    modifier onlyDuringActive(address owner) {
        if (wills[owner].state != WillState.ACTIVE) revert WillNotActive();
        _;
    }

    modifier onlyDuringClaiming(address owner) {
        if (wills[owner].state != WillState.CLAIMING) revert WillNotClaiming();
        _;
    }

    modifier notSettled(address owner) {
        if (wills[owner].state == WillState.SETTLED) revert WillAlreadySettled();
        _;
    }

    uint256 private _lockStatus = 1; // reentrancy

    modifier nonReentrant() {
        require(_lockStatus == 1, "Reentrant call");
        _lockStatus = 2;
        _;
        _lockStatus = 1;
    }

    constructor(address _rnsRegistry, address _trustedForwarder) {
        if (_rnsRegistry == address(0)) revert ZeroAddress();
        if (_trustedForwarder == address(0)) revert ZeroAddress();
        rnsRegistry = IRNSRegistry(_rnsRegistry);
        trustedForwarder = _trustedForwarder;
    }

    function createWill(uint256 heartbeatInterval, uint256 cooldownPeriod) external {
        address caller = _msgSender();
        if (wills[caller].state != WillState.INACTIVE) revert WillAlreadyExists();
        if (heartbeatInterval < MIN_HEARTBEAT) revert BelowMinimumHeartbeat();
        if (cooldownPeriod < MIN_COOLDOWN) revert BelowMinimumCooldown();

        Will storage w = wills[caller];
        w.state = WillState.ACTIVE;
        w.heartbeatInterval = heartbeatInterval;
        w.cooldownPeriod = cooldownPeriod;
        w.lastAlive = block.timestamp;

        emit WillCreated(caller, heartbeatInterval, cooldownPeriod);
    }

    function depositRBTC() external payable onlyWillOwner onlyDuringActive(_msgSender()) {
        if (msg.value == 0) revert ZeroAmount();
        address caller = _msgSender();
        wills[caller].rbtcBalance += msg.value;
        _resetHeartbeat(caller);
        emit Deposited(caller, RBTC, msg.value);
    }

    function depositToken(address token, uint256 amount) external onlyWillOwner onlyDuringActive(_msgSender()) {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        address caller = _msgSender();
        bool ok = IERC20(token).transferFrom(caller, address(this), amount);
        if (!ok) revert TransferFailed();

        wills[caller].tokenBalance[token] += amount;
        _resetHeartbeat(caller);
        emit Deposited(caller, token, amount);
    }

    function withdrawRBTC(uint256 amount) external onlyWillOwner onlyDuringActive(_msgSender()) nonReentrant {
        if (amount == 0) revert ZeroAmount();
        address caller = _msgSender();
        if (wills[caller].rbtcBalance < amount) revert InsufficientBalance();

        wills[caller].rbtcBalance -= amount;
        _resetHeartbeat(caller);

        (bool sent,) = caller.call{value: amount}("");
        if (!sent) revert TransferFailed();

        emit Withdrawn(caller, RBTC, amount);
    }

    function withdrawToken(address token, uint256 amount)
        external
        onlyWillOwner
        onlyDuringActive(_msgSender())
        nonReentrant
    {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        address caller = _msgSender();
        if (wills[caller].tokenBalance[token] < amount) revert InsufficientBalance();

        wills[caller].tokenBalance[token] -= amount;
        _resetHeartbeat(caller);

        bool ok = IERC20(token).transfer(caller, amount);
        if (!ok) revert TransferFailed();

        emit Withdrawn(caller, token, amount);
    }

    function stillAlive(uint256 newInterval) external onlyWillOwner onlyDuringActive(_msgSender()) {
        address caller = _msgSender();

        if (newInterval != 0) {
            if (newInterval < MIN_HEARTBEAT) revert BelowMinimumHeartbeat();
            wills[caller].heartbeatInterval = newInterval;
            emit HeartbeatUpdated(caller, newInterval);
        }

        _resetHeartbeat(caller);
        emit StillAlive(caller, block.timestamp + wills[caller].heartbeatInterval);
    }

    function configureAsset(address asset, address[] calldata beneficiaries, uint256[] calldata bpsAllocations)
        external
        onlyWillOwner
        onlyDuringActive(_msgSender())
    {
        address caller = _msgSender();
        Will storage w = wills[caller];

        if (beneficiaries.length != bpsAllocations.length) revert AllocationMismatch();

        // validate allocation is 100%
        uint256 total = 0;
        for (uint256 i = 0; i < bpsAllocations.length; i++) {
            total += bpsAllocations[i];
        }
        if (total != TOTAL_BPS) revert AllocationMismatch();
        AssetAllocation storage aa = w.allocations[asset];
        if (aa.beneficiaries.length == 0) {
            w.configuredAssets.push(asset);
        } else {
            _clearAssetAllocation(aa);
        }

        // new allocation
        for (uint256 i = 0; i < beneficiaries.length; i++) {
            address ben = beneficiaries[i];
            if (ben == address(0)) revert ZeroAddress();
            if (aa.index[ben] != 0) revert BeneficiaryAlreadyAdded();

            aa.beneficiaries.push(Beneficiary({wallet: ben, bps: bpsAllocations[i]}));
            aa.index[ben] = aa.beneficiaries.length; // store index+1

            emit BeneficiaryAdded(caller, asset, ben, bpsAllocations[i]);
        }

        _resetHeartbeat(caller);
    }

    function addBeneficiaryByName(address asset, bytes32 rnsName, uint256 bps)
        external
        onlyWillOwner
        onlyDuringActive(_msgSender())
    {
        address resolved = _resolveRNS(rnsName);
        _addBeneficiary(_msgSender(), asset, resolved, bps);
    }

    function addBeneficiary(address asset, address beneficiary, uint256 bps)
        external
        onlyWillOwner
        onlyDuringActive(_msgSender())
    {
        _addBeneficiary(_msgSender(), asset, beneficiary, bps);
    }

    function removeBeneficiary(address asset, address beneficiary)
        external
        onlyWillOwner
        onlyDuringActive(_msgSender())
    {
        address caller = _msgSender();
        Will storage w = wills[caller];
        AssetAllocation storage aa = w.allocations[asset];

        uint256 idx1 = aa.index[beneficiary];
        if (idx1 == 0) revert BeneficiaryNotFound();

        uint256 idx = idx1 - 1;
        uint256 freedBps = aa.beneficiaries[idx].bps;

        // swap with last and pop
        uint256 lastIdx = aa.beneficiaries.length - 1;
        if (idx != lastIdx) {
            aa.beneficiaries[idx] = aa.beneficiaries[lastIdx];
            aa.index[aa.beneficiaries[lastIdx].wallet] = idx + 1;
        }
        aa.beneficiaries.pop();
        delete aa.index[beneficiary];

        // redistribute bps
        _rebalanceAfterRemoval(aa, freedBps);

        _resetHeartbeat(caller);
        emit BeneficiaryRemoved(caller, asset, beneficiary);
    }

    function initiateClaim(address willOwner) external onlyDuringActive(willOwner) {
        Will storage w = wills[willOwner];
        if (block.timestamp < w.lastAlive + w.heartbeatInterval) {
            revert HeartbeatStillRunning();
        }
        address caller = _msgSender();
        if (!_isBeneficiary(w, caller)) revert NotABeneficiary();

        w.state = WillState.CLAIMING;
        w.claimInitiatedAt = block.timestamp;

        emit ClaimInitiated(willOwner, caller, block.timestamp);
    }

    function cancelClaim() external onlyWillOwner onlyDuringClaiming(_msgSender()) {
        address caller = _msgSender();
        wills[caller].state = WillState.ACTIVE;
        _resetHeartbeat(caller);

        emit ClaimCancelled(caller);
    }

    function distributeFunds(address willOwner) external onlyDuringClaiming(willOwner) nonReentrant {
        Will storage w = wills[willOwner];

        if (block.timestamp < w.claimInitiatedAt + w.cooldownPeriod) {
            revert CooldownNotOver();
        }
        w.state = WillState.SETTLED;
        for (uint256 i = 0; i < w.configuredAssets.length; i++) {
            address asset = w.configuredAssets[i];
            _distributeAsset(willOwner, w, asset);
        }

        emit WillDistributed(willOwner);
    }

    // read contract data
    function willState(address owner) external view returns (WillState) {
        return wills[owner].state; // current state of will
    }

    function heartbeatLapsed(address owner) external view returns (bool) {
        Will storage w = wills[owner];
        return block.timestamp >= w.lastAlive + w.heartbeatInterval;
    }

    function claimableAfter(address owner) external view returns (uint256) {
        Will storage w = wills[owner];
        return w.lastAlive + w.heartbeatInterval;
    }

    function distributableAfter(address owner) external view returns (uint256) {
        Will storage w = wills[owner];
        if (w.state != WillState.CLAIMING) return 0;
        return w.claimInitiatedAt + w.cooldownPeriod;
    }

    function rbtcBalance(address owner) external view returns (uint256) {
        return wills[owner].rbtcBalance;
    }

    function tokenBalance(address owner, address token) external view returns (uint256) {
        return wills[owner].tokenBalance[token];
    }

    function assetBeneficiaries(address owner, address asset)
        external
        view
        returns (address[] memory wallets, uint256[] memory allocations)
    {
        AssetAllocation storage aa = wills[owner].allocations[asset];
        uint256 len = aa.beneficiaries.length;
        wallets = new address[](len);
        allocations = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            wallets[i] = aa.beneficiaries[i].wallet;
            allocations[i] = aa.beneficiaries[i].bps;
        }
    }

    function configuredAssets(address owner) external view returns (address[] memory) {
        return wills[owner].configuredAssets;
    }

    // helpers
    function _resetHeartbeat(address owner) internal {
        wills[owner].lastAlive = block.timestamp;
    }

    function _msgSender() internal view returns (address sender) {
        if (msg.sender == trustedForwarder && msg.data.length >= 20) {
            // The forwarder appends the original sender's address to calldata
            assembly {
                sender := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            sender = msg.sender;
        }
    }

    function _resolveRNS(bytes32 nameHash) internal view returns (address resolved) {
        address resolverAddr = rnsRegistry.resolver(nameHash);
        if (resolverAddr == address(0)) revert RNSResolutionFailed();
        resolved = IRNSResolver(resolverAddr).addr(nameHash);
        if (resolved == address(0)) revert RNSResolutionFailed();
    }

    function _addBeneficiary(address caller, address asset, address beneficiary, uint256 bps) internal {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (bps == 0 || bps >= TOTAL_BPS) revert AllocationMismatch();

        Will storage w = wills[caller];
        AssetAllocation storage aa = w.allocations[asset];
        if (aa.index[beneficiary] != 0) revert BeneficiaryAlreadyAdded();
        _rebalanceBeforeAddition(aa, bps);

        aa.beneficiaries.push(Beneficiary({wallet: beneficiary, bps: bps}));
        aa.index[beneficiary] = aa.beneficiaries.length;

        _resetHeartbeat(caller);
        emit BeneficiaryAdded(caller, asset, beneficiary, bps);
    }

    function _rebalanceBeforeAddition(AssetAllocation storage aa, uint256 bpsNeeded) internal {
        uint256 len = aa.beneficiaries.length;
        uint256 currentTotal = TOTAL_BPS;
        uint256 newTotal = currentTotal - bpsNeeded;
        uint256 assigned = 0;
        uint256 largestIdx = 0;
        uint256 largestBps = 0;

        for (uint256 i = 0; i < len; i++) {
            uint256 newBps = (aa.beneficiaries[i].bps * newTotal) / currentTotal;
            aa.beneficiaries[i].bps = newBps;
            assigned += newBps;
            if (newBps > largestBps) {
                largestBps = newBps;
                largestIdx = i;
            }
        }

        // give dust to beneficiary with highest bps
        uint256 dust = newTotal - assigned;
        if (dust > 0 && len > 0) {
            aa.beneficiaries[largestIdx].bps += dust;
        }
    }

    function _rebalanceAfterRemoval(AssetAllocation storage aa, uint256 freedBps) internal {
        uint256 len = aa.beneficiaries.length;
        if (len == 0) return;

        uint256 oldTotal = TOTAL_BPS - freedBps;
        uint256 assigned = 0;
        uint256 largestIdx = 0;
        uint256 largestBps = 0;

        for (uint256 i = 0; i < len; i++) {
            uint256 newBps = (aa.beneficiaries[i].bps * TOTAL_BPS) / oldTotal;
            aa.beneficiaries[i].bps = newBps;
            assigned += newBps;
            if (newBps > largestBps) {
                largestBps = newBps;
                largestIdx = i;
            }
        }

        uint256 dust = TOTAL_BPS - assigned;
        if (dust > 0) {
            aa.beneficiaries[largestIdx].bps += dust;
        }
    }

    function _clearAssetAllocation(AssetAllocation storage aa) internal {
        for (uint256 i = 0; i < aa.beneficiaries.length; i++) {
            delete aa.index[aa.beneficiaries[i].wallet];
        }
        delete aa.beneficiaries;
    }

    function _isBeneficiary(Will storage w, address caller) internal view returns (bool) {
        for (uint256 i = 0; i < w.configuredAssets.length; i++) {
            if (w.allocations[w.configuredAssets[i]].index[caller] != 0) {
                return true;
            }
        }
        return false;
    }

    function _distributeAsset(address willOwner, Will storage w, address asset) internal {
        AssetAllocation storage aa = w.allocations[asset];
        uint256 len = aa.beneficiaries.length;
        if (len == 0) return;

        if (asset == RBTC) {
            uint256 total = w.rbtcBalance;
            w.rbtcBalance = 0;
            uint256 remaining = total;

            for (uint256 i = 0; i < len - 1; i++) {
                uint256 share = (total * aa.beneficiaries[i].bps) / TOTAL_BPS;
                remaining -= share;
                (bool sent,) = aa.beneficiaries[i].wallet.call{value: share}("");
                if (sent) {
                    emit AssetDistributed(willOwner, asset, aa.beneficiaries[i].wallet, share);
                }
            }

            // last beneficiary gets the remaining dust
            (bool lastSent,) = aa.beneficiaries[len - 1].wallet.call{value: remaining}("");
            if (lastSent) {
                emit AssetDistributed(willOwner, asset, aa.beneficiaries[len - 1].wallet, remaining);
            }
        } else {
            uint256 total = w.tokenBalance[asset];
            w.tokenBalance[asset] = 0;
            uint256 remaining = total;

            for (uint256 i = 0; i < len - 1; i++) {
                uint256 share = (total * aa.beneficiaries[i].bps) / TOTAL_BPS;
                remaining -= share;
                bool ok = _safeTokenTransfer(asset, aa.beneficiaries[i].wallet, share);
                if (ok) {
                    emit AssetDistributed(willOwner, asset, aa.beneficiaries[i].wallet, share);
                }
            }

            bool lastOk = _safeTokenTransfer(asset, aa.beneficiaries[len - 1].wallet, remaining);
            if (lastOk) {
                emit AssetDistributed(willOwner, asset, aa.beneficiaries[len - 1].wallet, remaining);
            }
        }
    }

    function _safeTokenTransfer(address token, address to, uint256 amount) internal returns (bool) {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        return success && (data.length == 0 || abi.decode(data, (bool)));
    }

    receive() external payable {}
}
