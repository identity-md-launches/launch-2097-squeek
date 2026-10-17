// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SqueekToken} from "src/SqueekToken.sol";

/// @dev A closed set of holders makes conservation measurable. The ledger starts from the
/// requested supply and records successful operations, never copying balances from the token.
contract SqueekTokenHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    SqueekToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    uint256 public nonzeroTransfers;
    uint256 public nonzeroDelegatedTransfers;
    uint256 public rejectedCalls;

    constructor() {
        actors[0] = address(this);
        actors[1] = makeAddr("invariant.alice");
        actors[2] = makeAddr("invariant.bob");
        actors[3] = makeAddr("invariant.carol");
        token = new SqueekToken();
        expectedBalance[address(this)] = SUPPLY;

        // Fund every actor and seed a ring of approvals so delegated transfers are reachable
        // immediately. Subsequent approvals, revocations and transfers may empty any account.
        for (uint256 i = 1; i < actors.length; ++i) {
            _transfer(address(this), actors[i], SUPPLY / 4);
        }
        for (uint256 i; i < actors.length; ++i) {
            _approve(actors[i], actors[(i + 1) % actors.length], SUPPLY / 8);
        }
        nonzeroTransfers = 0;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        _transfer(from, _actor(toSeed), _amount(amountSeed, expectedBalance[from]));
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        uint256 mode = amountSeed % 4;
        uint256 amount = mode == 0
            ? 0
            : mode == 1 ? type(uint256).max : mode == 2 ? type(uint256).max - 1 : bound(amountSeed, 0, SUPPLY);
        _approve(_actor(ownerSeed), _actor(spenderSeed), amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = expectedAllowance[owner][spender];
        uint256 limit = expectedBalance[owner] < allowed ? expectedBalance[owner] : allowed;
        uint256 amount = _amount(amountSeed, limit);

        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "delegated transfer returned false");
        _recordTransfer(owner, to, amount);
        if (allowed != type(uint256).max) expectedAllowance[owner][spender] = allowed - amount;
        if (amount > 0) ++nonzeroDelegatedTransfers;
    }

    function transferTooMuch(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        uint256 balance = expectedBalance[from];
        uint256 amount = bound(amountSeed, balance + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount));
        vm.prank(from);
        token.transfer(_actor(toSeed), amount);
        ++rejectedCalls;
    }

    function revokeAndAttemptSpend(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        _approve(owner, spender, 0);
        uint256 amount = bound(amountSeed, 1, SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, amount));
        vm.prank(spender);
        token.transferFrom(owner, _actor(toSeed), amount);
        ++rejectedCalls;
    }

    function transferFromTooMuch(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 balance = expectedBalance[owner];
        uint256 amount = bound(amountSeed, balance + 1, type(uint256).max);
        // A finite approval exercises rollback of the allowance debit before the balance check.
        // The max-uint input also exercises the infinite-approval path.
        _approve(owner, spender, amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount));
        vm.prank(spender);
        token.transferFrom(owner, _actor(toSeed), amount);
        ++rejectedCalls;
    }

    function transferToZero(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, bool delegated) external {
        address owner = _actor(ownerSeed);
        uint256 amount = _amount(amountSeed, expectedBalance[owner]);
        if (delegated) {
            address spender = _actor(spenderSeed);
            _approve(owner, spender, amount);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(spender);
            token.transferFrom(owner, address(0), amount);
        } else {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(owner);
            token.transfer(address(0), amount);
        }
        ++rejectedCalls;
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(_actor(ownerSeed));
        token.approve(address(0), amount);
        ++rejectedCalls;
    }

    /// @dev Called after a campaign, excluded from the randomized selector list. Each holder
    /// must still be able to move its entire balance using only its own authority.
    function sweepToDeployer() external {
        for (uint256 i = 1; i < actors.length; ++i) {
            _transfer(actors[i], actors[0], expectedBalance[actors[i]]);
        }
        assertEq(token.balanceOf(actors[0]), SUPPLY, "holders could not recover the whole supply");
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approval returned false");
        expectedAllowance[owner][spender] = amount;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "transfer returned false");
        _recordTransfer(from, to, amount);
        if (amount > 0) ++nonzeroTransfers;
    }

    function _recordTransfer(address from, address to, uint256 amount) internal {
        // Self-transfers have no net effect, but transferFrom still spends their allowance.
        if (from != to) {
            expectedBalance[from] -= amount;
            expectedBalance[to] += amount;
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _amount(uint256 seed, uint256 limit) internal pure returns (uint256) {
        // Explicitly bias towards zero, one minor unit and the whole available amount.
        uint256 mode = seed % 5;
        if (mode == 0) return 0;
        if (mode == 1) return limit == 0 ? 0 : 1;
        if (mode == 2) return limit;
        return bound(seed, 0, limit);
    }
}

/// @dev Unexpected reverts (including handler assertions) must fail the campaign. Expected
/// failures are checked inside the handler and leave the ghost ledger unchanged.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract SqueekTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    SqueekTokenHandler internal handler;
    SqueekToken internal token;

    function setUp() public {
        handler = new SqueekTokenHandler();
        token = handler.token();

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.transferTooMuch.selector;
        selectors[4] = handler.revokeAndAttemptSpend.selector;
        selectors[5] = handler.transferFromTooMuch.selector;
        selectors[6] = handler.transferToZero.selector;
        selectors[7] = handler.approveZeroSpender.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_fixedSupplyEqualsSumOfAllHolders() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(token.totalSupply(), SUPPLY, "supply changed after deployment");
        assertEq(sum, SUPPLY, "tokens created, destroyed or diverted outside the actor set");
        assertEq(token.balanceOf(address(0)), 0, "zero address acquired tokens");
    }

    function invariant_balancesMatchSuccessfulTransfers() public view {
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor), "holder balance disagrees with ledger");
        }
    }

    function invariant_allowancesMatchOwnerConsent() public view {
        for (uint256 i; i < 4; ++i) {
            address owner = handler.actors(i);
            assertEq(token.allowance(owner, address(0)), 0, "zero spender acquired an allowance");
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.expectedAllowance(owner, spender),
                    "approval, consumption or rollback disagrees with owner consent"
                );
            }
        }
    }

    function afterInvariant() public {
        handler.sweepToDeployer();
        invariant_fixedSupplyEqualsSumOfAllHolders();
        invariant_balancesMatchSuccessfulTransfers();
        invariant_allowancesMatchOwnerConsent();
    }

    /// @dev A deterministic sequence proves that every handler is usable and that both kinds
    /// of successful transfer move nonzero amounts; random campaigns add ordering and inputs.
    function test_handlerExercisesSuccessFailureAndRecovery() public {
        handler.transfer(0, 1, 1);
        handler.approve(1, 2, 103);
        handler.transferFrom(1, 2, 3, 2);
        handler.transferFrom(0, 1, 0, 1);
        handler.transferTooMuch(0, 1, type(uint256).max);
        handler.revokeAndAttemptSpend(1, 2, 3, 1);
        handler.transferFromTooMuch(2, 3, 0, type(uint256).max - 1);
        handler.transferToZero(0, 1, 1, true);
        handler.transferToZero(0, 1, 0, false);
        handler.approveZeroSpender(0, 0);

        assertGt(handler.nonzeroTransfers(), 0);
        assertGt(handler.nonzeroDelegatedTransfers(), 0);
        assertEq(handler.rejectedCalls(), 6);
        invariant_fixedSupplyEqualsSumOfAllHolders();
        invariant_balancesMatchSuccessfulTransfers();
        invariant_allowancesMatchOwnerConsent();
        afterInvariant();
    }
}
