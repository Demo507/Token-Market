// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TCH8} from "../src/TCH8.sol";
import {Sale} from "../src/Sale.sol";

contract SaleTest is Test {
    TCH8 token;
    Sale sale;
    address gov = makeAddr("gov");
    address user = makeAddr("user");
    address other = makeAddr("other");
    address recipient = makeAddr("recipient");
    uint256 constant PRICE = 0.0001 ether; // wei per 1 TCH8  (1 ETH = 10,000 TCH8)

    function setUp() public {
        token = new TCH8("TCH8 Token", "TCH8", gov, 1_000_000_000e6);
        sale = new Sale(address(token), gov, PRICE);
        vm.prank(gov);
        token.addMinter(address(sale));
        vm.deal(user, 100 ether);
    }

    function test_constructor_validations() public {
        vm.expectRevert(Sale.ZeroAddressError.selector);
        new Sale(address(0), gov, PRICE);
        vm.expectRevert(Sale.ZeroAddressError.selector);
        new Sale(address(token), address(0), PRICE);
        vm.expectRevert(Sale.ZeroAmountError.selector);
        new Sale(address(token), gov, 0);
    }

    function test_buy_mintsTokensAtPrice() public {
        vm.prank(user);
        sale.buy{value: 1 ether}();
        // 1 ETH buys 10,000 TCH8
        assertEq(token.balanceOf(user), 10_000e6);
        assertEq(address(sale).balance, 1 ether);
    }

    function test_receive_buysToo() public {
        vm.prank(user);
        (bool ok, ) = address(sale).call{value: 2 ether}("");
        assertTrue(ok);
        assertEq(token.balanceOf(user), 20_000e6);
    }

    function test_buy_emitsAndRecordsPurchase() public {
        vm.expectEmit(true, false, false, true);
        emit Sale.Purchased(user, 1 ether, 10_000e6);
        vm.prank(user);
        sale.buy{value: 1 ether}();

        assertEq(sale.purchaseCount(), 1);
        (address b, uint256 eth, uint256 out, uint256 ts) = sale.purchases(0);
        assertEq(b, user);
        assertEq(eth, 1 ether);
        assertEq(out, 10_000e6);
        assertEq(ts, block.timestamp);
    }

    function test_buy_revertsOnZeroValue() public {
        vm.prank(user);
        vm.expectRevert(Sale.ZeroAmountError.selector);
        sale.buy{value: 0}();
    }

    function test_buy_revertsWhenTooSmallForOneUnit() public {
        vm.prank(user);
        vm.expectRevert(Sale.ZeroAmountError.selector);
        sale.buy{value: 1}(); // 1 wei rounds to 0 base units
    }

    function testFuzz_buy_matchesFormula(uint256 value) public {
        value = bound(value, 1e12, 100 ether);
        vm.prank(user);
        sale.buy{value: value}();
        assertEq(token.balanceOf(user), (value * 1e6) / PRICE);
    }

    function test_setPrice_changesRate() public {
        vm.prank(gov);
        sale.setPrice(0.0002 ether); // 1 ETH = 5,000 TCH8
        vm.prank(user);
        sale.buy{value: 1 ether}();
        assertEq(token.balanceOf(user), 5_000e6);
    }

    function test_setPrice_onlyGovernanceAndNonZero() public {
        vm.prank(other);
        vm.expectRevert(Sale.OnlyGovernanceError.selector);
        sale.setPrice(1);

        vm.prank(gov);
        vm.expectRevert(Sale.ZeroAmountError.selector);
        sale.setPrice(0);
    }

    function test_withdraw_sendsEthToRecipient() public {
        vm.prank(user);
        sale.buy{value: 1 ether}();
        vm.prank(gov);
        sale.withdraw(payable(recipient), 0.4 ether);
        assertEq(recipient.balance, 0.4 ether);
        assertEq(address(sale).balance, 0.6 ether);
    }

    function test_withdraw_guards() public {
        vm.prank(user);
        sale.buy{value: 1 ether}();

        vm.prank(other);
        vm.expectRevert(Sale.OnlyGovernanceError.selector);
        sale.withdraw(payable(recipient), 1);

        vm.prank(gov);
        vm.expectRevert(Sale.ZeroAddressError.selector);
        sale.withdraw(payable(address(0)), 1);

        // TCH8 has no receive(), so the ETH transfer fails
        vm.prank(gov);
        vm.expectRevert(Sale.WithdrawFailedError.selector);
        sale.withdraw(payable(address(token)), 1);
    }

    function test_buy_failsIfSaleIsNotMinter() public {
        vm.prank(gov);
        token.removeMinter(address(sale));
        vm.prank(user);
        vm.expectRevert(TCH8.OnlyMinterError.selector);
        sale.buy{value: 1 ether}();
    }

    function test_governanceTransfer_twoStep() public {
        vm.prank(gov);
        sale.setGovernance(other);
        vm.prank(user);
        vm.expectRevert(Sale.OnlyPendingGovernanceError.selector);
        sale.acceptGovernance();
        vm.prank(other);
        sale.acceptGovernance();
        assertEq(sale.governance(), other);
        assertEq(sale.pendingGovernance(), address(0));
    }
}
