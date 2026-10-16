// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {TCH8} from "../src/TCH8.sol";

contract TCH8Test is Test {
    TCH8 token;
    address gov = makeAddr("gov");
    address minter = makeAddr("minter");
    address user = makeAddr("user");
    address other = makeAddr("other");
    uint256 constant MAX = 1_000_000e6;

    function setUp() public {
        token = new TCH8("TCH8 Token", "TCH8", gov, MAX);
        vm.prank(gov);
        token.addMinter(minter);
    }

    function test_metadata() public view {
        assertEq(token.name(), "TCH8 Token");
        assertEq(token.symbol(), "TCH8");
        assertEq(token.decimals(), 6);
        assertEq(token.maxSupply(), MAX);
        assertEq(token.governance(), gov);
    }

    function test_constructor_revertsOnZeroGovernance() public {
        vm.expectRevert(TCH8.ZeroAddressError.selector);
        new TCH8("x", "x", address(0), MAX);
    }

    function test_mint_byMinter() public {
        vm.prank(minter);
        token.mint(user, 5e6);
        assertEq(token.balanceOf(user), 5e6);
        assertEq(token.totalSupply(), 5e6);
    }

    function test_mint_revertsIfNotMinter() public {
        vm.prank(other);
        vm.expectRevert(TCH8.OnlyMinterError.selector);
        token.mint(user, 1e6);
    }

    function test_mint_revertsToZeroAddress() public {
        vm.prank(minter);
        vm.expectRevert(TCH8.ZeroAddressError.selector);
        token.mint(address(0), 1e6);
    }

    function test_mint_revertsAboveMaxSupply() public {
        vm.startPrank(minter);
        token.mint(user, MAX);
        vm.expectRevert(TCH8.MaxSupplyExceededError.selector);
        token.mint(user, 1);
        vm.stopPrank();
    }

    function testFuzz_mint_respectsMaxSupply(uint256 amount) public {
        amount = bound(amount, 0, MAX);
        vm.prank(minter);
        token.mint(user, amount);
        assertEq(token.totalSupply(), amount);
        assertLe(token.totalSupply(), MAX);
    }

    function test_burn_byMinterBurnsOwnBalance() public {
        vm.startPrank(minter);
        token.mint(minter, 10e6);
        token.burn(4e6);
        vm.stopPrank();
        assertEq(token.balanceOf(minter), 6e6);
        assertEq(token.totalSupply(), 6e6);
    }

    function test_burn_revertsIfNotMinter() public {
        vm.prank(other);
        vm.expectRevert(TCH8.OnlyMinterError.selector);
        token.burn(1);
    }

    function test_burn_revertsOnInsufficientBalance() public {
        vm.prank(minter);
        vm.expectRevert(TCH8.InsufficientBalanceError.selector);
        token.burn(1);
    }

    function test_transfer_works() public {
        vm.prank(minter);
        token.mint(user, 3e6);
        vm.prank(user);
        token.transfer(other, 1e6);
        assertEq(token.balanceOf(other), 1e6);
        assertEq(token.balanceOf(user), 2e6);
    }

    function test_pause_blocksTransfersAndUnpauseRestores() public {
        vm.prank(minter);
        token.mint(user, 3e6);

        vm.prank(gov);
        token.pause();
        vm.prank(user);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.transfer(other, 1e6);

        vm.prank(gov);
        token.unpause();
        vm.prank(user);
        token.transfer(other, 1e6);
        assertEq(token.balanceOf(other), 1e6);
    }

    function test_pause_onlyGovernance() public {
        vm.prank(other);
        vm.expectRevert(TCH8.OnlyGovernanceError.selector);
        token.pause();
    }

    function test_addAndRemoveMinter() public {
        vm.prank(gov);
        token.addMinter(other);
        assertTrue(token.isMinter(other));
        vm.prank(gov);
        token.removeMinter(other);
        assertFalse(token.isMinter(other));
    }

    function test_addMinter_onlyGovernanceAndNonZero() public {
        vm.prank(other);
        vm.expectRevert(TCH8.OnlyGovernanceError.selector);
        token.addMinter(other);

        vm.prank(gov);
        vm.expectRevert(TCH8.ZeroAddressError.selector);
        token.addMinter(address(0));
    }

    function test_governanceTransfer_twoStep() public {
        vm.prank(gov);
        token.setGovernance(other);
        assertEq(token.pendingGovernance(), other);
        assertEq(token.governance(), gov);

        vm.prank(user);
        vm.expectRevert(TCH8.OnlyPendingGovernanceError.selector);
        token.acceptGovernance();

        vm.prank(other);
        token.acceptGovernance();
        assertEq(token.governance(), other);
        assertEq(token.pendingGovernance(), address(0));
    }

    function test_setGovernance_revertsOnZeroOrNonGov() public {
        vm.prank(gov);
        vm.expectRevert(TCH8.ZeroAddressError.selector);
        token.setGovernance(address(0));

        vm.prank(other);
        vm.expectRevert(TCH8.OnlyGovernanceError.selector);
        token.setGovernance(other);
    }
}
