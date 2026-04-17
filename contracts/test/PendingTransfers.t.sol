// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PendingTransfers} from "../src/PendingTransfers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*//////////////////////////////////////////////////////////////
                        MINIMAL ERC-20 MOCK
//////////////////////////////////////////////////////////////*/

/// @dev Bare-bones ERC-20 for happy-path token tests. Non-malicious.
contract MockERC20 is IERC20 {
    string public name = "Mock";
    string public symbol = "MCK";
    uint8  public constant decimals = 18;
    uint256 public override totalSupply;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply   += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external virtual override returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        unchecked { balanceOf[from] -= amount; }
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/*//////////////////////////////////////////////////////////////
                   REENTRANT ERC-20 (for nonReentrant test)
//////////////////////////////////////////////////////////////*/

/// @dev An ERC-20 that tries to re-enter `claim` during `transfer`. If ReentrancyGuard
///      works, the re-entry call reverts and the outer call still succeeds — so the
///      first claim goes through exactly once. If it DIDN'T work, the attacker would
///      double-spend. We assert the single-spend property.
contract ReentrantERC20 is MockERC20 {
    PendingTransfers public target;
    bytes32 public reenterId;
    bytes32 public reenterSecret;
    bool    public armed;

    function arm(PendingTransfers _target, bytes32 _id, bytes32 _secret) external {
        target = _target;
        reenterId = _id;
        reenterSecret = _secret;
        armed = true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        if (armed) {
            armed = false; // one-shot
            // Attempt to re-enter claim() on the same id. Must revert inside.
            try target.claim(reenterId, reenterSecret) {
                revert("reentry succeeded - ReentrancyGuard broken");
            } catch {
                // swallow — the revert is the expected path
            }
        }
        _move(msg.sender, to, amount);
        return true;
    }
}

/*//////////////////////////////////////////////////////////////
                            TESTS
//////////////////////////////////////////////////////////////*/

contract PendingTransfersTest is Test {
    PendingTransfers internal pt;
    MockERC20 internal token;

    address internal alice = makeAddr("alice");   // sender
    address internal bob   = makeAddr("bob");     // receiver
    address internal eve   = makeAddr("eve");     // attacker / wrong-recipient

    bytes32 internal constant SECRET_A = bytes32(uint256(0xAAAA));
    bytes32 internal constant SECRET_B = bytes32(uint256(0xBBBB));

    uint64 internal expiry; // computed fresh per test

    function setUp() public {
        pt    = new PendingTransfers();
        token = new MockERC20();
        vm.deal(alice, 100 ether);
        vm.deal(bob,   1 ether);
        vm.deal(eve,   1 ether);
        token.mint(alice, 1_000_000 ether);

        // Default expiry: now + 1 hour (inside MIN_EXPIRY..MAX_EXPIRY).
        expiry = uint64(block.timestamp + 1 hours);
    }

    /*──────────────────────── helpers ────────────────────────*/

    /// @dev Mirror of PendingTransfers._computeCommit. If this diverges, every
    ///      claim in every test will revert — so this is the canonical oracle
    ///      for the commit formula.
    function _commit(bytes32 id, bytes32 secret) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, secret));
    }

    function _previewAndCommit(
        address sender,
        address receiver,
        address tkn,
        uint256 amount,
        bytes32 secret
    ) internal view returns (bytes32 id, bytes32 commit) {
        id = pt.previewId(sender, receiver, tkn, amount);
        commit = _commit(id, secret);
    }

    /*──────────────────────── CREATE (native) ────────────────*/

    function test_createETH_happy() public {
        (bytes32 previewed, bytes32 commit) =
            _previewAndCommit(alice, bob, address(0), 1 ether, SECRET_A);

        vm.prank(alice);
        bytes32 id = pt.createETH{value: 1 ether}(bob, commit, expiry);

        assertEq(id, previewed, "previewId must match real id");
        assertEq(address(pt).balance, 1 ether, "escrow holds funds");
        PendingTransfers.Pending memory t = pt.getTransfer(id);
        assertEq(t.sender, alice);
        assertEq(t.receiver, bob);
        assertEq(uint8(t.status), uint8(PendingTransfers.Status.Pending));
    }

    function test_createETH_revert_zeroAmount() public {
        (, bytes32 commit) = _previewAndCommit(alice, bob, address(0), 0, SECRET_A);
        vm.prank(alice);
        vm.expectRevert(PendingTransfers.BadAmount.selector);
        pt.createETH{value: 0}(bob, commit, expiry);
    }

    function test_createETH_revert_zeroReceiver() public {
        (, bytes32 commit) = _previewAndCommit(alice, address(0), address(0), 1 ether, SECRET_A);
        vm.prank(alice);
        vm.expectRevert(PendingTransfers.BadAmount.selector);
        pt.createETH{value: 1 ether}(address(0), commit, expiry);
    }

    function test_createETH_revert_zeroCommit() public {
        vm.prank(alice);
        vm.expectRevert(PendingTransfers.BadCommit.selector);
        pt.createETH{value: 1 ether}(bob, bytes32(0), expiry);
    }

    function test_createETH_revert_expiryTooShort() public {
        (, bytes32 commit) = _previewAndCommit(alice, bob, address(0), 1 ether, SECRET_A);
        vm.prank(alice);
        vm.expectRevert(PendingTransfers.BadExpiry.selector);
        // MIN_EXPIRY - 1s — just below the floor
        pt.createETH{value: 1 ether}(bob, commit, uint64(block.timestamp + 10 minutes - 1));
    }

    function test_createETH_revert_expiryTooLong() public {
        (, bytes32 commit) = _previewAndCommit(alice, bob, address(0), 1 ether, SECRET_A);
        vm.prank(alice);
        vm.expectRevert(PendingTransfers.BadExpiry.selector);
        pt.createETH{value: 1 ether}(bob, commit, uint64(block.timestamp + 7 days + 1));
    }

    /*──────────────────────── CLAIM (native) ─────────────────*/

    function test_claim_happy() public {
        (, bytes32 commit) = _previewAndCommit(alice, bob, address(0), 1 ether, SECRET_A);
        vm.prank(alice);
        bytes32 id = pt.createETH{value: 1 ether}(bob, commit, expiry);

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        pt.claim(id, SECRET_A);

        assertEq(bob.balance, bobBefore + 1 ether, "bob got the ETH");
        assertEq(address(pt).balance, 0, "escrow drained");
        assertEq(
            uint8(pt.getTransfer(id).status),
            uint8(PendingTransfers.Status.Claimed)
        );
    }

    function test_claim_revert_wrongReceiver() public {
        (, bytes32 commit) = _previewAndCommit(alice, bob, address(0), 1 ether, SECRET_A);
        vm.prank(alice);
        bytes32 id = pt.createETH{value: 1 ether}(bob, commit, expiry);

        vm.prank(eve);
        vm.expectRevert(PendingTransfers.NotReceiver.selector);
        pt.claim(id, SECRET_A);
    }

    function test_claim_revert_wrongSecret() public {
        (, bytes32 commit) = _previewAndCommit(alice, bob, address(0), 1 ether, SECRET_A);
        vm.prank(alice);
        bytes32 id = pt.createETH{value: 1 ether}(bob, commit, expiry);

        vm.prank(bob);
        vm.expectRevert(PendingTransfers.BadSecret.selector);
        pt.claim(id, SECRET_B);
    }

    function test_claim_revert_afterExpiry() public {
        (, bytes32 commit) = _previewAndCommit(alice, bob, address(0), 1 ether, SECRET_A);
        vm.prank(alice);
        bytes32 id = pt.createETH{value: 1 ether}(bob, commit, expiry);

        vm.warp(expiry + 1);
        vm.prank(bob);
        vm.expectRevert(PendingTransfers.Expired.selector);
        pt.claim(id, SECRET_A);
    }

    function test_claim_revert_doubleClaim() public {
        (, bytes32 commit) = _previewAndCommit(alice, bob, address(0), 1 ether, SECRET_A);
        vm.prank(alice);
        bytes32 id = pt.createETH{value: 1 ether}(bob, commit, expiry);

        vm.prank(bob);
        pt.claim(id, SECRET_A);

        vm.prank(bob);
        vm.expectRevert(PendingTransfers.AlreadySettled.selector);
        pt.claim(id, SECRET_A);
    }

    /*──────────────────────── CANCEL (native) ────────────────*/

    function test_cancel_happy_whilePending() public {
        (, bytes32 commit) = _previewAndCommit(alice, bob, address(0), 1 ether, SECRET_A);
        vm.prank(alice);
        bytes32 id = pt.createETH{value: 1 ether}(bob, commit, expiry);

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        pt.cancel(id);

        assertEq(alice.balance, aliceBefore + 1 ether, "alice refunded");
        assertEq(address(pt).balance, 0);
        assertEq(
            uint8(pt.getTransfer(id).status),
            uint8(PendingTransfers.Status.Cancelled)
        );
    }

    function test_cancel_happy_afterExpiry() public {
        (, bytes32 commit) = _previewAndCommit(alice, bob, address(0), 1 ether, SECRET_A);
        vm.prank(alice);
        bytes32 id = pt.createETH{value: 1 ether}(bob, commit, expiry);

        vm.warp(expiry + 1 days);
        vm.prank(alice);
        pt.cancel(id);

        assertEq(alice.balance, 100 ether, "alice back to starting balance");
    }

    function test_cancel_revert_notSender() public {
        (, bytes32 commit) = _previewAndCommit(alice, bob, address(0), 1 ether, SECRET_A);
        vm.prank(alice);
        bytes32 id = pt.createETH{value: 1 ether}(bob, commit, expiry);

        vm.prank(bob);
        vm.expectRevert(PendingTransfers.NotSender.selector);
        pt.cancel(id);
    }

    function test_cancel_revert_afterClaim() public {
        (, bytes32 commit) = _previewAndCommit(alice, bob, address(0), 1 ether, SECRET_A);
        vm.prank(alice);
        bytes32 id = pt.createETH{value: 1 ether}(bob, commit, expiry);

        vm.prank(bob);
        pt.claim(id, SECRET_A);

        vm.prank(alice);
        vm.expectRevert(PendingTransfers.AlreadySettled.selector);
        pt.cancel(id);
    }

    function test_claim_revert_afterCancel() public {
        (, bytes32 commit) = _previewAndCommit(alice, bob, address(0), 1 ether, SECRET_A);
        vm.prank(alice);
        bytes32 id = pt.createETH{value: 1 ether}(bob, commit, expiry);

        vm.prank(alice);
        pt.cancel(id);

        vm.prank(bob);
        vm.expectRevert(PendingTransfers.AlreadySettled.selector);
        pt.claim(id, SECRET_A);
    }

    /*──────────────────────── ERC-20 path ────────────────────*/

    function test_createERC20_and_claim_happy() public {
        uint256 amt = 500 ether;
        (, bytes32 commit) = _previewAndCommit(alice, bob, address(token), amt, SECRET_A);

        vm.startPrank(alice);
        token.approve(address(pt), amt);
        bytes32 id = pt.createERC20(bob, address(token), amt, commit, expiry);
        vm.stopPrank();

        assertEq(token.balanceOf(address(pt)), amt);

        vm.prank(bob);
        pt.claim(id, SECRET_A);

        assertEq(token.balanceOf(bob), amt, "bob got the tokens");
        assertEq(token.balanceOf(address(pt)), 0, "escrow drained");
    }

    function test_createERC20_revert_nativeSentinel() public {
        vm.prank(alice);
        vm.expectRevert(PendingTransfers.BadAmount.selector);
        pt.createERC20(bob, address(0), 1 ether, keccak256("x"), expiry);
    }

    /*──────────────────────── nonce uniqueness ───────────────*/

    function test_identicalParams_produceDistinctIds() public {
        (, bytes32 commit1) = _previewAndCommit(alice, bob, address(0), 1 ether, SECRET_A);
        vm.prank(alice);
        bytes32 id1 = pt.createETH{value: 1 ether}(bob, commit1, expiry);

        (, bytes32 commit2) = _previewAndCommit(alice, bob, address(0), 1 ether, SECRET_B);
        vm.prank(alice);
        bytes32 id2 = pt.createETH{value: 1 ether}(bob, commit2, expiry);

        assertTrue(id1 != id2, "nonce must distinguish successive creates");
    }

    /*──────────────────────── receive() rejection ────────────*/

    function test_stray_ether_reverts() public {
        vm.prank(alice);
        (bool ok,) = address(pt).call{value: 1 ether}("");
        assertFalse(ok, "plain send must revert");
    }

    /*──────────────────────── REENTRANCY ─────────────────────*/

    function test_reentrancy_protection() public {
        ReentrantERC20 bad = new ReentrantERC20();
        bad.mint(alice, 100 ether);

        uint256 amt = 10 ether;
        bytes32 id = pt.previewId(alice, bob, address(bad), amt);
        bytes32 commit = _commit(id, SECRET_A);

        vm.startPrank(alice);
        bad.approve(address(pt), amt);
        pt.createERC20(bob, address(bad), amt, commit, expiry);
        vm.stopPrank();

        // Arm the token so its next transfer() tries to reenter claim(id).
        bad.arm(pt, id, SECRET_A);

        vm.prank(bob);
        pt.claim(id, SECRET_A);

        // If the outer claim ALSO reverted, bob wouldn't have the tokens.
        // If reentry SUCCEEDED (guard broken), the mock would have revert()ed loudly.
        assertEq(bad.balanceOf(bob), amt, "claim succeeded exactly once");
        assertEq(
            uint8(pt.getTransfer(id).status),
            uint8(PendingTransfers.Status.Claimed)
        );
    }
}
