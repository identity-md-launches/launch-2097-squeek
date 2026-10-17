// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SqueekToken} from "src/SqueekToken.sol";

/// @dev Complements the original suite with arithmetic boundaries, address aliasing and
/// allowance lifecycle/rollback properties. All token balances come from real transfers.
/// forge-config: default.fuzz.runs = 1000
contract SqueekTokenEdgeCasesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    SqueekToken internal token;
    address internal deployer = makeAddr("edge.deployer");
    address internal alice = makeAddr("edge.alice");
    address internal bob = makeAddr("edge.bob");
    address internal spender = makeAddr("edge.spender");

    function setUp() public {
        vm.prank(deployer);
        token = new SqueekToken();
    }

    function test_constructorEmitsExactlyOneMintToCreatorNotOrigin() public {
        vm.recordLogs();
        vm.prank(alice, bob);
        SqueekToken second = new SqueekToken();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1, "constructor must emit one mint");
        assertEq(logs[0].emitter, address(second));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(alice))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
        assertEq(second.balanceOf(alice), SUPPLY);
        assertEq(second.balanceOf(bob), 0);
        assertEq(second.balanceOf(address(second)), 0);
        assertEq(second.balanceOf(address(0)), 0);
        assertEq(second.totalSupply(), SUPPLY);
    }

    function test_oneMinorUnitCanBeTransferredAndReturned() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1));
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(deployer), SUPPLY - 1);
        vm.prank(alice);
        assertTrue(token.transfer(deployer, 1));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroTransferFromEmptyAccountEmitsTransfer() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_zeroTransferFromNeedsNoBalanceOrAllowanceAndEmitsTransfer() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(token.allowance(alice, spender), 0);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_zeroTransferStillRejectsZeroReceiver() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(alice);
        token.transfer(address(0), 0);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_zeroTransferFromStillRejectsZeroReceiver() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(alice, address(0), 0);
        assertEq(token.allowance(alice, spender), 0);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_zeroApprovalStillRejectsZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(alice);
        token.approve(address(0), 0);
        assertEq(token.allowance(alice, address(0)), 0);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_maximumTransferRevertsWithoutChangingBalances() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        vm.prank(deployer);
        token.transfer(alice, type(uint256).max);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_infiniteApprovalCannotAuthorizeMoreThanTheOwnerBalance() public {
        _approve(deployer, spender, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        vm.prank(spender);
        token.transferFrom(deployer, alice, type(uint256).max);
        assertEq(token.allowance(deployer, spender), type(uint256).max);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_maximumMinusOneIsFiniteAllowance() public {
        _approve(deployer, spender, type(uint256).max - 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, 1));
        assertEq(token.allowance(deployer, spender), type(uint256).max - 2);
        _assertBalances(SUPPLY - 1, 1, 0);
    }

    function test_infiniteAllowanceCanBeReplacedAndRevoked() public {
        _approve(deployer, spender, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, 1));
        assertEq(token.allowance(deployer, spender), type(uint256).max);

        _approve(deployer, spender, 2);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, 1));
        assertEq(token.allowance(deployer, spender), 1);

        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(deployer, spender, 0);
        _approve(deployer, spender, 0);
        _expectAllowanceFailure(deployer, spender, alice, 0, 1);
        assertEq(token.allowance(deployer, spender), 0);
        _assertBalances(SUPPLY - 2, 2, 0);
    }

    function test_infiniteApprovalCanBeRevokedDirectly() public {
        _approve(deployer, spender, type(uint256).max);
        _approve(deployer, spender, 0);
        _expectAllowanceFailure(deployer, spender, alice, 0, 1);
        assertEq(token.allowance(deployer, spender), 0);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_selfTransferOfWholeBalanceEmitsWithoutChangingBalanceOrAllowance() public {
        _approve(deployer, spender, 17);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(deployer, deployer, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, SUPPLY));
        assertEq(token.allowance(deployer, spender), 17);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_selfTransferCannotExceedBalance() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1)
        );
        vm.prank(deployer);
        token.transfer(deployer, SUPPLY + 1);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_delegatedSelfTransferConsumesAllowanceWithoutMovingTokens() public {
        _approve(deployer, spender, 7);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(deployer, deployer, 7);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, deployer, 7));
        assertEq(token.allowance(deployer, spender), 0);
        _expectAllowanceFailure(deployer, spender, deployer, 0, 1);
        _assertBalances(SUPPLY, 0, 0);
    }

    function test_ownerCallingTransferFromStillNeedsSelfApproval() public {
        _expectAllowanceFailure(deployer, deployer, alice, 0, 1);
        _approve(deployer, deployer, 1);
        vm.prank(deployer);
        assertTrue(token.transferFrom(deployer, alice, 1));
        assertEq(token.allowance(deployer, deployer), 0);
        _assertBalances(SUPPLY - 1, 1, 0);
    }

    function test_approvalDoesNotLockFundsAndCanBeUsedAfterRefill() public {
        _approve(deployer, spender, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, 0, 1));
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, spender), SUPPLY, "failed pull consumed allowance");

        vm.prank(alice);
        assertTrue(token.transfer(deployer, 1));
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, 1));
        assertEq(token.allowance(deployer, spender), SUPPLY - 1);
        _assertBalances(0, SUPPLY - 1, 1);
    }

    function test_exhaustedAllowanceCannotSpendAgainAfterOwnerRefill() public {
        _approve(deployer, spender, SUPPLY);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, SUPPLY));
        assertEq(token.allowance(deployer, spender), 0);
        vm.prank(alice);
        assertTrue(token.transfer(deployer, SUPPLY));
        _expectAllowanceFailure(deployer, spender, alice, 0, 1);
        _assertBalances(SUPPLY, 0, 0);
    }

    function testFuzz_failedDelegatedTransferRollsBackAllowance(uint256 held, uint256 requested, bool infinite) public {
        held = bound(held, 0, SUPPLY);
        requested = bound(requested, held + 1, type(uint256).max - 1);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, held));
        uint256 approval = infinite ? type(uint256).max : requested;
        _approve(alice, spender, approval);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, requested));
        vm.prank(spender);
        token.transferFrom(alice, bob, requested);

        assertEq(token.allowance(alice, spender), approval, "failed transfer consumed allowance");
        _assertBalances(SUPPLY - held, held, 0);
    }

    function testFuzz_invalidRecipientRollsBackAllowance(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        _approve(deployer, spender, amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(deployer, address(0), amount);
        assertEq(token.allowance(deployer, spender), amount, "invalid recipient consumed allowance");
        _assertBalances(SUPPLY, 0, 0);

        // The same approval remains usable with a valid recipient after the rejected attempt.
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, amount));
        assertEq(token.allowance(deployer, spender), 0);
        _assertBalances(SUPPLY - amount, amount, 0);
    }

    function testFuzz_spenderCannotUseAnotherSpendersApproval(uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        _approve(deployer, alice, amount);
        _expectAllowanceFailure(deployer, spender, bob, 0, amount);
        assertEq(token.allowance(deployer, alice), amount);
        assertEq(token.allowance(deployer, spender), 0);
        _assertBalances(SUPPLY, 0, 0);

        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, amount));
        assertEq(token.allowance(deployer, alice), 0);
        _assertBalances(SUPPLY - amount, 0, amount);
    }

    function testFuzz_approvalReplacementIsIdempotentAndIsolated(uint256 initial, uint256 replacement) public {
        _approve(alice, spender, initial);
        _approve(bob, spender, 23);
        _approve(alice, bob, 37);
        _approve(alice, spender, replacement);
        _approve(alice, spender, replacement);

        assertEq(token.allowance(alice, spender), replacement);
        assertEq(token.allowance(bob, spender), 23);
        assertEq(token.allowance(alice, bob), 37);
        assertEq(token.allowance(spender, alice), 0);
        _assertBalances(SUPPLY, 0, 0);
    }

    function testFuzz_spendingOneAllowanceDoesNotChangeAnother(uint256 first, uint256 second, uint256 amount) public {
        _approve(deployer, spender, first);
        _approve(deployer, bob, second);
        _approve(alice, spender, second);
        amount = bound(amount, 0, first < SUPPLY ? first : SUPPLY);

        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, amount));
        assertEq(token.allowance(deployer, spender), first == type(uint256).max ? first : first - amount);
        assertEq(token.allowance(deployer, bob), second);
        assertEq(token.allowance(alice, spender), second);
        _assertBalances(SUPPLY - amount, amount, 0);
    }

    function testFuzz_transferRoundTripRestoresBalancesAndPreservesApproval(uint256 amount, uint256 split) public {
        amount = bound(amount, 0, SUPPLY);
        split = bound(split, 0, amount);
        _approve(deployer, spender, type(uint256).max);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, amount));
        vm.prank(alice);
        assertTrue(token.transfer(bob, split));
        _assertBalances(SUPPLY - amount, amount - split, split);

        vm.prank(bob);
        assertTrue(token.transfer(deployer, split));
        vm.prank(alice);
        assertTrue(token.transfer(deployer, amount - split));
        assertEq(token.allowance(deployer, spender), type(uint256).max);
        _assertBalances(SUPPLY, 0, 0);
    }

    function testFuzz_finiteAllowanceCannotBeSpentTwice(uint256 amount) public {
        amount = bound(amount, 1, SUPPLY);
        _approve(deployer, spender, amount);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, amount));
        assertEq(token.allowance(deployer, spender), 0);
        _expectAllowanceFailure(deployer, spender, alice, 0, amount);
        assertEq(token.allowance(deployer, spender), 0);
        _assertBalances(SUPPLY - amount, amount, 0);
    }

    function _approve(address owner, address delegate, uint256 amount) internal {
        vm.prank(owner);
        assertTrue(token.approve(delegate, amount));
    }

    function _expectAllowanceFailure(address owner, address delegate, address to, uint256 allowed, uint256 amount)
        internal
    {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, delegate, allowed, amount)
        );
        vm.prank(delegate);
        token.transferFrom(owner, to, amount);
    }

    function _assertBalances(uint256 deployerBalance, uint256 aliceBalance, uint256 bobBalance) internal view {
        assertEq(token.balanceOf(deployer), deployerBalance);
        assertEq(token.balanceOf(alice), aliceBalance);
        assertEq(token.balanceOf(bob), bobBalance);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
