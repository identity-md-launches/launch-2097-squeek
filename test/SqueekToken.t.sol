// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SqueekToken} from "../src/SqueekToken.sol";
import {DeploySqueekToken} from "../script/DeploySqueekToken.s.sol";

/// @notice Deploys the token from a contract, the way the launch factory does, so the tests can
/// check that `msg.sender` of the creation (a contract, not an EOA) receives the whole supply.
contract FactoryStandIn {
    SqueekToken public token;

    function launch() external returns (SqueekToken) {
        token = new SqueekToken();
        return token;
    }

    function send(address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract SqueekTokenTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 ether;
    uint256 internal constant SWARM_BPS = 1_000;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal spender = makeAddr("spender");

    SqueekToken internal token;

    function setUp() public {
        vm.prank(deployer);
        token = new SqueekToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Squeek");
        assertEq(token.symbol(), "SQUEEK");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "Squeek");
        assertEq(token.TOKEN_SYMBOL(), "SQUEEK");
        assertEq(token.DECIMALS(), 18);
    }

    function test_totalSupplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), alice, EXPECTED_SUPPLY);
        vm.prank(alice);
        new SqueekToken();
    }

    /// @dev The launch factory is a contract. The supply must land on it exactly as on an EOA.
    function test_supplyGoesToTheDeployingContract() public {
        FactoryStandIn factory = new FactoryStandIn();
        SqueekToken launched = factory.launch();
        assertEq(launched.totalSupply(), EXPECTED_SUPPLY);
        assertEq(launched.balanceOf(address(factory)), EXPECTED_SUPPLY);
        assertEq(launched.balanceOf(address(this)), 0);
    }

    function test_twoDeploymentsAreIndependent() public {
        vm.prank(alice);
        SqueekToken second = new SqueekToken();
        assertEq(second.balanceOf(alice), EXPECTED_SUPPLY);
        assertEq(second.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: success
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesExactAmountAndEmits() public {
        uint256 amount = 12_345 ether;
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, alice, amount);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_transferWholeBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, EXPECTED_SUPPLY));
        assertEq(token.balanceOf(alice), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, 1 ether));
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    /// @dev Mirrors the launch flow: 10% to the distributor, then the distributor pays a claimant.
    /// Both legs must arrive whole and the supply must not change.
    function test_launchFlowsArriveWhole() public {
        FactoryStandIn factory = new FactoryStandIn();
        SqueekToken launched = factory.launch();
        address distributor = makeAddr("distributor");
        address claimant = makeAddr("claimant");
        uint256 swarm = (EXPECTED_SUPPLY * SWARM_BPS) / 10_000;

        assertTrue(factory.send(distributor, swarm));
        assertEq(launched.balanceOf(distributor), swarm);
        assertEq(launched.balanceOf(address(factory)), EXPECTED_SUPPLY - swarm);

        vm.prank(distributor);
        assertTrue(launched.transfer(claimant, swarm));
        assertEq(launched.balanceOf(claimant), swarm);
        assertEq(launched.balanceOf(distributor), 0);
        assertEq(launched.totalSupply(), EXPECTED_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: failure
    // ---------------------------------------------------------------------------------------------

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 5 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 5 ether, 6 ether));
        vm.prank(alice);
        token.transfer(bob, 6 ether);
        assertEq(token.balanceOf(alice), 5 ether);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferRevertsFromEmptyAccount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), 1 ether);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_transferMoreThanSupplyReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, deployer, EXPECTED_SUPPLY, EXPECTED_SUPPLY + 1
            )
        );
        vm.prank(deployer);
        token.transfer(alice, EXPECTED_SUPPLY + 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Approvals and transferFrom
    // ---------------------------------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(deployer, spender, 100 ether);
        vm.prank(deployer);
        assertTrue(token.approve(spender, 100 ether));
        assertEq(token.allowance(deployer, spender), 100 ether);
    }

    function test_approveOverwritesPreviousAllowance() public {
        vm.startPrank(deployer);
        token.approve(spender, 100 ether);
        token.approve(spender, 7 ether);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), 7 ether);
    }

    function test_approveRevertsForZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(deployer);
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowanceExactly() public {
        vm.prank(deployer);
        token.approve(spender, 100 ether);

        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, alice, 40 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, 40 ether));

        assertEq(token.balanceOf(alice), 40 ether);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - 40 ether);
        assertEq(token.allowance(deployer, spender), 60 ether);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_transferFromWithInfiniteAllowanceDoesNotDecrement() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(deployer, alice, 1 ether);
        assertEq(token.allowance(deployer, spender), type(uint256).max);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1 ether));
        vm.prank(spender);
        token.transferFrom(deployer, alice, 1 ether);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_transferFromRevertsAboveAllowance() public {
        vm.prank(deployer);
        token.approve(spender, 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 10 ether, 11 ether)
        );
        vm.prank(spender);
        token.transferFrom(deployer, alice, 11 ether);
        assertEq(token.allowance(deployer, spender), 10 ether);
    }

    function test_transferFromRevertsWhenOwnerBalanceTooLow() public {
        vm.prank(alice);
        token.approve(spender, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1 ether));
        vm.prank(spender);
        token.transferFrom(alice, bob, 1 ether);
    }

    /// @dev Nobody can pull a holder's tokens without that holder's approval, not even the deployer.
    function test_deployerCannotTransferFromAHolderWithoutApproval() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        vm.prank(deployer);
        token.transferFrom(alice, deployer, 1);
        assertEq(token.balanceOf(alice), 10 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // No privileged surface
    // ---------------------------------------------------------------------------------------------

    /// @dev The token exposes no mint, burn, pause, freeze or ownership entry points. Every such
    /// selector must fall through to a revert and leave supply and balances untouched.
    function test_noAdminSelectorsExist() public {
        string[18] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "setOwner(address)",
            "transferOwnership(address)",
            "renounceOwnership()",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "setMinter(address)",
            "seize(address)"
        ];
        address[2] memory callers = [deployer, address(0xBEEF)];
        for (uint256 c; c < callers.length; ++c) {
            for (uint256 i; i < signatures.length; ++i) {
                bytes memory data = abi.encodeWithSignature(signatures[i], callers[c], type(uint128).max);
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, signatures[i]);
            }
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(0xBEEF)), 0);
    }

    function test_rejectsPlainEtherAndUnknownCalls() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "token accepted ether");
        vm.prank(alice);
        (ok,) = address(token).call(hex"deadbeef");
        assertFalse(ok, "token accepted an unknown selector");
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Deploy script
    // ---------------------------------------------------------------------------------------------

    function test_deployScriptMintsToCaller() public {
        DeploySqueekToken deployScript = new DeploySqueekToken();
        SqueekToken deployed = deployScript.deploy();
        assertEq(deployed.totalSupply(), EXPECTED_SUPPLY);
        assertEq(deployed.balanceOf(address(deployScript)), EXPECTED_SUPPLY);
        assertEq(deployed.name(), "Squeek");
        assertEq(deployed.symbol(), "SQUEEK");
        assertEq(deployed.decimals(), 18);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), token.totalSupply());
    }

    function testFuzz_transferAboveBalanceReverts(address to, uint256 amount) public {
        vm.assume(to != address(0));
        amount = bound(amount, EXPECTED_SUPPLY + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, EXPECTED_SUPPLY, amount)
        );
        vm.prank(deployer);
        token.transfer(to, amount);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, EXPECTED_SUPPLY);
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.approve(spender, allowed);
        vm.prank(spender);
        if (amount > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
            );
            token.transferFrom(deployer, alice, amount);
            assertEq(token.balanceOf(alice), 0);
            assertEq(token.allowance(deployer, spender), allowed);
        } else {
            assertTrue(token.transferFrom(deployer, alice, amount));
            assertEq(token.balanceOf(alice), amount);
            assertEq(token.allowance(deployer, spender), allowed - amount);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_chainedTransfersConserveSupply(uint256 a, uint256 b) public {
        a = bound(a, 0, EXPECTED_SUPPLY);
        b = bound(b, 0, a);
        vm.prank(deployer);
        token.transfer(alice, a);
        vm.prank(alice);
        token.transfer(bob, b);
        assertEq(token.balanceOf(deployer) + token.balanceOf(alice) + token.balanceOf(bob), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(alice), a - b);
        assertEq(token.balanceOf(bob), b);
    }
}
