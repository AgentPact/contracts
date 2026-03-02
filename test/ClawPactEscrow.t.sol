// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ClawPactEscrowV2} from "../src/ClawPactEscrowV2.sol";
import {IClawPactEscrow} from "../src/interfaces/IClawPactEscrow.sol";

contract ClawPactEscrowTest is Test {
    ClawPactEscrowV2 public escrow;

    // Actors
    address public owner = makeAddr("owner");
    address public requester = makeAddr("requester");
    address public provider = makeAddr("provider");
    address public platformFund = makeAddr("platformFund");
    address public stranger = makeAddr("stranger");

    // Platform signer keypair (for EIP-712)
    uint256 public signerPrivateKey = 0xA11CE;
    address public platformSigner;

    // Test constants
    bytes32 public constant TASK_HASH = keccak256("test-task-requirements");
    bytes32 public constant DELIVERY_HASH =
        keccak256("test-delivery-artifacts");
    bytes32 public constant REASON_HASH = keccak256("revision-reason");
    bytes32 public constant CRITERIA_HASH = keccak256("criteria-results");

    function setUp() public {
        platformSigner = vm.addr(signerPrivateKey);

        // Deploy implementation
        ClawPactEscrowV2 impl = new ClawPactEscrowV2();

        // Deploy proxy
        bytes memory initData = abi.encodeCall(
            ClawPactEscrowV2.initialize,
            (platformSigner, platformFund, owner)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        escrow = ClawPactEscrowV2(payable(address(proxy)));

        // Fund actors
        vm.deal(requester, 100 ether);
        vm.deal(provider, 10 ether);
    }

    // ========================= Helpers =========================

    /// @dev Create a standard escrow and return escrowId
    function _createEscrow() internal returns (uint256) {
        return _createEscrowWithParams(3, 48, 1.05 ether);
    }

    function _createEscrowWithParams(
        uint8 maxRevisions,
        uint8 acceptHours,
        uint256 value
    ) internal returns (uint256) {
        uint64 deadline = uint64(block.timestamp + 7 days);
        vm.prank(requester);
        return
            escrow.createEscrow{value: value}(
                TASK_HASH,
                deadline,
                maxRevisions,
                acceptHours
            );
    }

    /// @dev Generate platform EIP-712 signature for claimTask
    function _signAssignment(
        uint256 escrowId,
        address agent,
        uint256 nonce,
        uint256 expiredAt
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                escrow.ASSIGNMENT_TYPEHASH(),
                escrowId,
                agent,
                nonce,
                expiredAt
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Replicate EIP-712 digest calculation
    function _hashTypedDataV4(
        bytes32 structHash
    ) internal view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    escrow.getDomainSeparator(),
                    structHash
                )
            );
    }

    /// @dev Full flow: create → claim → confirm
    function _createAndAssign() internal returns (uint256 escrowId) {
        escrowId = _createEscrow();
        uint256 expiredAt = block.timestamp + 30 minutes;
        bytes memory sig = _signAssignment(escrowId, provider, 0, expiredAt);
        vm.prank(provider);
        escrow.claimTask(escrowId, 0, expiredAt, sig);
        vm.prank(provider);
        escrow.confirmTask(escrowId);
    }

    /// @dev Full flow: create → claim → confirm → deliver
    function _createAssignAndDeliver() internal returns (uint256 escrowId) {
        escrowId = _createAndAssign();
        vm.prank(provider);
        escrow.submitDelivery(escrowId, DELIVERY_HASH);
    }

    // ========================= Test: createEscrow =========================

    function test_createEscrow_success() public {
        uint256 escrowId = _createEscrow();
        assertEq(escrowId, 1);

        IClawPactEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);
        assertEq(r.requester, requester);
        assertEq(uint8(r.state), uint8(IClawPactEscrow.TaskState.Created));
        assertEq(r.taskHash, TASK_HASH);
        assertEq(r.maxRevisions, 3);
        assertEq(r.acceptanceWindowHours, 48);
        // With 1.05 ETH and 5% deposit rate: reward = 1.05 * 100 / 105 = 1 ETH
        assertEq(r.rewardAmount, 1 ether);
        assertEq(r.requesterDeposit, 0.05 ether);
    }

    function test_createEscrow_differentDepositRates() public {
        // maxRevisions=5 → 8% deposit
        uint256 id1 = _createEscrowWithParams(5, 48, 1.08 ether);
        IClawPactEscrow.EscrowRecord memory r1 = escrow.getEscrow(id1);
        assertEq(r1.rewardAmount, 1 ether);
        assertEq(r1.requesterDeposit, 0.08 ether);

        // maxRevisions=7 → 12% deposit
        uint256 id2 = _createEscrowWithParams(7, 48, 1.12 ether);
        IClawPactEscrow.EscrowRecord memory r2 = escrow.getEscrow(id2);
        assertEq(r2.rewardAmount, 1 ether);
        assertEq(r2.requesterDeposit, 0.12 ether);
    }

    function test_createEscrow_revert_invalidDeadline() public {
        vm.prank(requester);
        vm.expectRevert(ClawPactEscrowV2.InvalidDeadline.selector);
        escrow.createEscrow{value: 1 ether}(
            TASK_HASH,
            uint64(block.timestamp - 1),
            3,
            48
        );
    }

    function test_createEscrow_revert_invalidMaxRevisions() public {
        vm.prank(requester);
        vm.expectRevert(ClawPactEscrowV2.InvalidMaxRevisions.selector);
        escrow.createEscrow{value: 1 ether}(
            TASK_HASH,
            uint64(block.timestamp + 1 days),
            0,
            48
        );
    }

    function test_createEscrow_revert_zeroValue() public {
        vm.prank(requester);
        vm.expectRevert(ClawPactEscrowV2.ZeroAmount.selector);
        escrow.createEscrow{value: 0}(
            TASK_HASH,
            uint64(block.timestamp + 1 days),
            3,
            48
        );
    }

    // ========================= Test: claimTask (EIP-712) =========================

    function test_claimTask_success() public {
        uint256 escrowId = _createEscrow();
        uint256 expiredAt = block.timestamp + 30 minutes;
        bytes memory sig = _signAssignment(escrowId, provider, 0, expiredAt);

        vm.prank(provider);
        escrow.claimTask(escrowId, 0, expiredAt, sig);

        IClawPactEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);
        assertEq(r.provider, provider);
        assertEq(
            uint8(r.state),
            uint8(IClawPactEscrow.TaskState.ConfirmationPending)
        );
        assertGt(r.confirmationDeadline, block.timestamp);
        assertEq(escrow.assignmentNonces(escrowId), 1); // nonce incremented
    }

    function test_claimTask_revert_expiredSignature() public {
        uint256 escrowId = _createEscrow();
        uint256 expiredAt = block.timestamp + 30 minutes;
        bytes memory sig = _signAssignment(escrowId, provider, 0, expiredAt);

        // Fast-forward past expiry
        vm.warp(expiredAt + 1);
        vm.prank(provider);
        vm.expectRevert(ClawPactEscrowV2.SignatureExpired.selector);
        escrow.claimTask(escrowId, 0, expiredAt, sig);
    }

    function test_claimTask_revert_invalidNonce() public {
        uint256 escrowId = _createEscrow();
        uint256 expiredAt = block.timestamp + 30 minutes;
        // Sign with wrong nonce
        bytes memory sig = _signAssignment(escrowId, provider, 99, expiredAt);

        vm.prank(provider);
        vm.expectRevert(ClawPactEscrowV2.InvalidNonce.selector);
        escrow.claimTask(escrowId, 99, expiredAt, sig);
    }

    function test_claimTask_revert_wrongAgent() public {
        uint256 escrowId = _createEscrow();
        uint256 expiredAt = block.timestamp + 30 minutes;
        // Signature is for provider, but stranger tries to use it
        bytes memory sig = _signAssignment(escrowId, provider, 0, expiredAt);

        vm.prank(stranger);
        vm.expectRevert(ClawPactEscrowV2.InvalidSignature.selector);
        escrow.claimTask(escrowId, 0, expiredAt, sig);
    }

    // ========================= Test: confirmTask / declineTask =========================

    function test_confirmTask_success() public {
        uint256 escrowId = _createEscrow();
        uint256 expiredAt = block.timestamp + 30 minutes;
        bytes memory sig = _signAssignment(escrowId, provider, 0, expiredAt);
        vm.prank(provider);
        escrow.claimTask(escrowId, 0, expiredAt, sig);

        vm.prank(provider);
        escrow.confirmTask(escrowId);

        IClawPactEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);
        assertEq(uint8(r.state), uint8(IClawPactEscrow.TaskState.Working));
    }

    function test_declineTask_success() public {
        uint256 escrowId = _createEscrow();
        uint256 expiredAt = block.timestamp + 30 minutes;
        bytes memory sig = _signAssignment(escrowId, provider, 0, expiredAt);
        vm.prank(provider);
        escrow.claimTask(escrowId, 0, expiredAt, sig);

        vm.prank(provider);
        escrow.declineTask(escrowId);

        IClawPactEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);
        assertEq(uint8(r.state), uint8(IClawPactEscrow.TaskState.Created));
        assertEq(r.provider, address(0));
        // Nonce was already incremented on claim, so new agent can claim with nonce=1
        assertEq(escrow.assignmentNonces(escrowId), 1);
    }

    // ========================= Test: submitDelivery + acceptDelivery =========================

    function test_fullFlow_deliverAndAccept() public {
        uint256 escrowId = _createAssignAndDeliver();

        IClawPactEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);
        assertEq(uint8(r.state), uint8(IClawPactEscrow.TaskState.Delivered));
        assertEq(r.latestDeliveryHash, DELIVERY_HASH);
        assertGt(r.acceptanceDeadline, block.timestamp);

        // Record balances before
        uint256 providerBefore = provider.balance;
        uint256 fundBefore = platformFund.balance;
        uint256 requesterBefore = requester.balance;

        // Accept delivery
        vm.prank(requester);
        escrow.acceptDelivery(escrowId);

        r = escrow.getEscrow(escrowId);
        assertEq(uint8(r.state), uint8(IClawPactEscrow.TaskState.Accepted));

        // Verify payouts: reward=1 ETH, fee=3%, deposit=0.05 ETH returned
        uint256 fee = (1 ether * 300) / 10_000; // 0.03 ETH
        assertEq(provider.balance - providerBefore, 1 ether - fee); // 0.97 ETH
        assertEq(platformFund.balance - fundBefore, fee); // 0.03 ETH
        assertEq(requester.balance - requesterBefore, 0.05 ether); // deposit returned
    }

    // ========================= Test: requestRevision + progressive penalty =========================

    function test_requestRevision_firstIsFree() public {
        uint256 escrowId = _createAssignAndDeliver();

        uint256 providerBefore = provider.balance;
        uint256 fundBefore = platformFund.balance;

        vm.prank(requester);
        escrow.requestRevision(escrowId, REASON_HASH, CRITERIA_HASH);

        IClawPactEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);
        assertEq(uint8(r.state), uint8(IClawPactEscrow.TaskState.InRevision));
        assertEq(r.currentRevision, 1);
        assertEq(r.depositConsumed, 0); // First revision is FREE

        // No penalty paid
        assertEq(provider.balance, providerBefore);
        assertEq(platformFund.balance, fundBefore);
    }

    function test_requestRevision_secondHasPenalty() public {
        uint256 escrowId = _createAssignAndDeliver();

        // First revision (free)
        vm.prank(requester);
        escrow.requestRevision(escrowId, REASON_HASH, CRITERIA_HASH);

        // Re-deliver
        vm.prank(provider);
        escrow.submitDelivery(escrowId, keccak256("delivery-v2"));

        uint256 providerBefore = provider.balance;
        uint256 fundBefore = platformFund.balance;

        // Second revision (10% penalty)
        vm.prank(requester);
        escrow.requestRevision(escrowId, REASON_HASH, CRITERIA_HASH);

        IClawPactEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);
        assertEq(r.currentRevision, 2);

        // Penalty = 0.05 ETH * 10% = 0.005 ETH
        uint256 penalty = (0.05 ether * 10) / 100;
        assertEq(r.depositConsumed, penalty);
        // 50% to provider, 50% to fund
        assertEq(provider.balance - providerBefore, penalty / 2);
        assertEq(platformFund.balance - fundBefore, penalty - penalty / 2);
    }

    // ========================= Test: Auto-Settlement =========================

    function test_autoSettle_atRevisionLimit() public {
        // Create escrow with maxRevisions=3
        uint256 escrowId = _createAssignAndDeliver();

        // Submit passRate before auto-settle triggers
        vm.prank(platformSigner);
        escrow.submitPassRate(escrowId, 65); // 65% pass rate

        // Revision 1 (free) → InRevision
        vm.prank(requester);
        escrow.requestRevision(escrowId, REASON_HASH, CRITERIA_HASH);

        // Re-deliver
        vm.prank(provider);
        escrow.submitDelivery(escrowId, keccak256("d2"));

        // Revision 2 (10% penalty) → InRevision
        vm.prank(requester);
        escrow.requestRevision(escrowId, REASON_HASH, CRITERIA_HASH);

        // Re-deliver
        vm.prank(provider);
        escrow.submitDelivery(escrowId, keccak256("d3"));

        uint256 providerBefore = provider.balance;
        uint256 requesterBefore = requester.balance;

        // Revision 3 (20% penalty) → triggers auto-settle (maxRevisions=3)
        vm.prank(requester);
        escrow.requestRevision(escrowId, REASON_HASH, CRITERIA_HASH);

        IClawPactEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);
        assertEq(uint8(r.state), uint8(IClawPactEscrow.TaskState.Settled));

        // Provider should get 65% of reward minus fee
        uint256 providerShare = (1 ether * 65) / 100; // 0.65 ETH
        uint256 fee = (providerShare * 300) / 10_000;
        assertTrue(provider.balance > providerBefore);
        assertTrue(requester.balance > requesterBefore); // 35% refund + remaining deposit
    }

    function test_autoSettle_passRateFloorAt30() public {
        uint256 escrowId = _createAssignAndDeliver();

        // Don't submit passRate (stays 0) → should floor to 30%
        // Fast-forward through all revisions
        for (uint8 i = 0; i < 2; i++) {
            vm.prank(requester);
            escrow.requestRevision(escrowId, REASON_HASH, CRITERIA_HASH);
            vm.prank(provider);
            escrow.submitDelivery(
                escrowId,
                keccak256(abi.encodePacked("d", i))
            );
        }

        uint256 providerBefore = provider.balance;

        // Last revision triggers auto-settle
        vm.prank(requester);
        escrow.requestRevision(escrowId, REASON_HASH, CRITERIA_HASH);

        // Provider gets at least 30% (MIN_PASS_RATE protection)
        uint256 minShare = (1 ether * 30) / 100;
        uint256 fee = (minShare * 300) / 10_000;
        assertTrue(provider.balance - providerBefore >= minShare - fee);
    }

    // ========================= Test: Timeouts =========================

    function test_acceptanceTimeout() public {
        uint256 escrowId = _createAssignAndDeliver();

        IClawPactEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);

        // Can't claim before deadline
        vm.prank(provider);
        vm.expectRevert(ClawPactEscrowV2.DeadlineNotReached.selector);
        escrow.claimAcceptanceTimeout(escrowId);

        // Fast-forward past acceptance deadline
        vm.warp(r.acceptanceDeadline + 1);

        uint256 providerBefore = provider.balance;

        vm.prank(provider);
        escrow.claimAcceptanceTimeout(escrowId);

        r = escrow.getEscrow(escrowId);
        assertEq(uint8(r.state), uint8(IClawPactEscrow.TaskState.TimedOut));

        // Provider gets full reward minus fee
        uint256 fee = (1 ether * 300) / 10_000;
        assertEq(provider.balance - providerBefore, 1 ether - fee);
    }

    function test_deliveryTimeout() public {
        uint256 escrowId = _createAndAssign();

        IClawPactEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);

        // Fast-forward past delivery deadline
        vm.warp(r.deliveryDeadline + 1);

        uint256 requesterBefore = requester.balance;

        vm.prank(requester);
        escrow.claimDeliveryTimeout(escrowId);

        r = escrow.getEscrow(escrowId);
        assertEq(uint8(r.state), uint8(IClawPactEscrow.TaskState.TimedOut));

        // Requester gets full refund (reward + deposit)
        assertEq(requester.balance - requesterBefore, 1.05 ether);
    }

    function test_confirmationTimeout() public {
        uint256 escrowId = _createEscrow();
        uint256 expiredAt = block.timestamp + 30 minutes;
        bytes memory sig = _signAssignment(escrowId, provider, 0, expiredAt);
        vm.prank(provider);
        escrow.claimTask(escrowId, 0, expiredAt, sig);

        IClawPactEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);

        // Fast-forward past confirmation deadline (2 hours)
        vm.warp(r.confirmationDeadline + 1);

        // Requester can trigger
        vm.prank(requester);
        escrow.claimConfirmationTimeout(escrowId);

        r = escrow.getEscrow(escrowId);
        assertEq(uint8(r.state), uint8(IClawPactEscrow.TaskState.Created));
        assertEq(r.provider, address(0));
    }

    // ========================= Test: cancelTask =========================

    function test_cancelTask_fromCreated() public {
        uint256 escrowId = _createEscrow();

        uint256 requesterBefore = requester.balance;

        vm.prank(requester);
        escrow.cancelTask(escrowId);

        IClawPactEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);
        assertEq(uint8(r.state), uint8(IClawPactEscrow.TaskState.Cancelled));
        assertEq(requester.balance - requesterBefore, 1.05 ether);
    }

    function test_cancelTask_revert_fromWorking() public {
        uint256 escrowId = _createAndAssign();

        vm.prank(requester);
        vm.expectRevert();
        escrow.cancelTask(escrowId);
    }

    // ========================= Test: Access Control =========================

    function test_onlyRequester_enforced() public {
        uint256 escrowId = _createAssignAndDeliver();

        vm.prank(stranger);
        vm.expectRevert(ClawPactEscrowV2.OnlyRequester.selector);
        escrow.acceptDelivery(escrowId);
    }

    function test_onlyProvider_enforced() public {
        uint256 escrowId = _createAndAssign();

        vm.prank(stranger);
        vm.expectRevert(ClawPactEscrowV2.OnlyProvider.selector);
        escrow.submitDelivery(escrowId, DELIVERY_HASH);
    }

    function test_onlyParties_enforced() public {
        uint256 escrowId = _createAssignAndDeliver();

        IClawPactEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);
        vm.warp(r.acceptanceDeadline + 1);

        vm.prank(stranger);
        vm.expectRevert(ClawPactEscrowV2.OnlyParties.selector);
        escrow.claimAcceptanceTimeout(escrowId);
    }

    // ========================= Test: Admin =========================

    function test_setPlatformSigner() public {
        address newSigner = makeAddr("newSigner");
        vm.prank(owner);
        escrow.setPlatformSigner(newSigner);
        assertEq(escrow.platformSigner(), newSigner);
    }

    function test_setPlatformSigner_revert_notOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        escrow.setPlatformSigner(makeAddr("x"));
    }

    function test_submitPassRate_revert_notSigner() public {
        vm.prank(stranger);
        vm.expectRevert(ClawPactEscrowV2.InvalidSignature.selector);
        escrow.submitPassRate(1, 50);
    }

    // ========================= Test: ERC20 (USDC) =========================

    function test_createEscrowERC20_fullFlow() public {
        // Deploy mock USDC (6 decimals like real USDC)
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);

        // Whitelist USDC
        vm.prank(owner);
        escrow.setAllowedToken(address(usdc), true);

        // Mint and approve
        uint256 totalAmount = 1_050 * 1e6; // $1050 USDC (reward $1000 + 5% deposit $50)
        usdc.mint(requester, totalAmount);
        vm.prank(requester);
        usdc.approve(address(escrow), totalAmount);

        // Create ERC20 escrow
        uint64 deadline = uint64(block.timestamp + 7 days);
        vm.prank(requester);
        uint256 escrowId = escrow.createEscrowERC20(
            TASK_HASH,
            deadline,
            3,
            48,
            address(usdc),
            totalAmount
        );

        IClawPactEscrow.EscrowRecord memory r = escrow.getEscrow(escrowId);
        assertEq(r.token, address(usdc));
        assertEq(r.rewardAmount, 1_000 * 1e6); // $1000
        assertEq(r.requesterDeposit, 50 * 1e6); // $50
        assertEq(usdc.balanceOf(address(escrow)), totalAmount);

        // Claim + confirm + deliver + accept
        uint256 expiredAt = block.timestamp + 30 minutes;
        bytes memory sig = _signAssignment(escrowId, provider, 0, expiredAt);
        vm.prank(provider);
        escrow.claimTask(escrowId, 0, expiredAt, sig);
        vm.prank(provider);
        escrow.confirmTask(escrowId);
        vm.prank(provider);
        escrow.submitDelivery(escrowId, DELIVERY_HASH);

        // Accept delivery
        vm.prank(requester);
        escrow.acceptDelivery(escrowId);

        // Verify USDC payouts
        uint256 fee = (1_000 * 1e6 * 300) / 10_000; // 3% = $30
        assertEq(usdc.balanceOf(provider), 1_000 * 1e6 - fee); // $970
        assertEq(usdc.balanceOf(platformFund), fee); // $30
        assertEq(usdc.balanceOf(requester), 50 * 1e6); // deposit returned
        assertEq(usdc.balanceOf(address(escrow)), 0); // escrow drained
    }

    function test_createEscrowERC20_revert_tokenNotAllowed() public {
        MockERC20 badToken = new MockERC20("Bad", "BAD", 18);
        badToken.mint(requester, 1000 ether);
        vm.prank(requester);
        badToken.approve(address(escrow), 1000 ether);

        vm.prank(requester);
        vm.expectRevert(ClawPactEscrowV2.TokenNotAllowed.selector);
        escrow.createEscrowERC20(
            TASK_HASH,
            uint64(block.timestamp + 7 days),
            3,
            48,
            address(badToken),
            1000 ether
        );
    }

    function test_setAllowedToken() public {
        address token = makeAddr("usdc");
        vm.prank(owner);
        escrow.setAllowedToken(token, true);
        assertTrue(escrow.allowedTokens(token));

        vm.prank(owner);
        escrow.setAllowedToken(token, false);
        assertFalse(escrow.allowedTokens(token));
    }
}

/// @dev Minimal ERC20 mock for testing
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
