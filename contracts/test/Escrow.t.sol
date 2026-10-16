// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TCH8} from "../src/TCH8.sol";
import {Escrow} from "../src/Escrow.sol";

contract EscrowTest is Test {
    TCH8 token;
    Escrow escrow;

    address gov = makeAddr("gov");
    address operator = makeAddr("operator");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address stranger = makeAddr("stranger");

    uint256 constant PRICE = 10e6; // 10 TCH8

    function setUp() public {
        token = new TCH8("TCH8 Token", "TCH8", gov, 1_000_000_000e6);
        escrow = new Escrow(address(token), gov, operator);

        vm.startPrank(gov);
        token.addMinter(address(escrow)); // needed so confirmRedemption can burn
        token.addMinter(gov);             // lets the test mint funds
        token.mint(buyer, 1_000e6);
        vm.stopPrank();
    }

    // ---------- helpers ----------
    function _list() internal returns (uint256 id) {
        vm.prank(seller);
        id = escrow.listItem("Sneakers", "Size 42", "https://img.example/a.png", PRICE, 1);
    }

    function _buy(uint256 itemId) internal returns (uint256 orderId) {
        vm.startPrank(buyer);
        token.approve(address(escrow), PRICE);
        orderId = escrow.createOrder(itemId);
        vm.stopPrank();
    }

    function _status(uint256 orderId) internal view returns (Escrow.Status s) {
        (, , , , , , , s) = escrow.orders(orderId);
    }

    function _toConfirmed() internal returns (uint256 orderId) {
        orderId = _buy(_list());
        vm.prank(seller);
        escrow.markDelivered(orderId);
        vm.prank(buyer);
        escrow.confirmDelivery(orderId);
    }

    // ---------- listing ----------
    function test_listItem_storesFields() public {
        uint256 id = _list();
        assertEq(id, 0);
        assertEq(escrow.itemCount(), 1);
        (address s, uint256 p, uint256 q, bool a, , string memory t, string memory d) = escrow.items(0);
        assertEq(s, seller);
        assertEq(p, PRICE);
        assertTrue(a);
        assertEq(q, 1);
        assertEq(t, "Sneakers");
        assertEq(d, "Size 42");
        assertEq(escrow.itemImage(0), "https://img.example/a.png");
    }

    function test_listItem_validations() public {
        vm.startPrank(seller);
        vm.expectRevert(Escrow.InvalidAmountError.selector);
        escrow.listItem("a", "b", "", 0, 1);
        vm.expectRevert(Escrow.InvalidInputError.selector);
        escrow.listItem("", "b", "", 1, 1);
        vm.expectRevert(Escrow.InvalidAmountError.selector);
        escrow.listItem("a", "b", "", 1, 0); // zero quantity
        vm.stopPrank();
    }

    function test_anyoneCanList() public {
        vm.prank(stranger);
        uint256 id = escrow.listItem("Book", "", "", 5e6, 1);
        (address s, , , , , , ) = escrow.items(id);
        assertEq(s, stranger);
    }

    function test_setItemActive_onlySellerAndBlocksPurchase() public {
        uint256 id = _list();

        vm.prank(buyer);
        vm.expectRevert(Escrow.NotSellerError.selector);
        escrow.setItemActive(id, false);

        vm.prank(seller);
        escrow.setItemActive(id, false);

        vm.startPrank(buyer);
        token.approve(address(escrow), PRICE);
        vm.expectRevert(Escrow.ItemInactiveError.selector);
        escrow.createOrder(id);
        vm.stopPrank();
    }

    // ---------- buying ----------
    function test_createOrder_movesTokensBuyerToEscrow() public {
        uint256 id = _list();
        uint256 before = token.balanceOf(buyer);

        vm.expectEmit(true, true, true, true);
        emit Escrow.OrderCreated(0, id, buyer, seller, PRICE);
        uint256 orderId = _buy(id);

        assertEq(token.balanceOf(buyer), before - PRICE);
        assertEq(token.balanceOf(address(escrow)), PRICE);
        assertEq(token.balanceOf(seller), 0);
        assertTrue(_status(orderId) == Escrow.Status.Paid);
    }

    function test_createOrder_sellerCannotBuyOwnItem() public {
        uint256 id = _list();
        vm.prank(gov);
        token.mint(seller, 100e6);
        vm.startPrank(seller);
        token.approve(address(escrow), PRICE);
        vm.expectRevert(Escrow.SelfPurchaseError.selector);
        escrow.createOrder(id);
        vm.stopPrank();
    }

    function test_createOrder_unknownItem() public {
        vm.prank(buyer);
        vm.expectRevert(Escrow.ItemNotFoundError.selector);
        escrow.createOrder(99);
    }

    function test_createOrder_revertsWithoutApproval() public {
        uint256 id = _list();
        vm.prank(buyer);
        vm.expectRevert(); // ERC20InsufficientAllowance
        escrow.createOrder(id);
    }

    function test_createOrder_revertsWithoutEnoughBalance() public {
        uint256 id = _list();
        vm.startPrank(stranger); // holds 0 TCH8
        token.approve(address(escrow), PRICE);
        vm.expectRevert(); // ERC20InsufficientBalance
        escrow.createOrder(id);
        vm.stopPrank();
    }

    function testFuzz_createOrder_holdsExactPrice(uint256 price) public {
        price = bound(price, 1, 1_000e6);
        vm.prank(seller);
        uint256 id = escrow.listItem("Fuzz", "", "", price, 1);
        vm.startPrank(buyer);
        token.approve(address(escrow), price);
        escrow.createOrder(id);
        vm.stopPrank();
        assertEq(token.balanceOf(address(escrow)), price);
    }

    // ---------- delivery / confirmation / redeem ----------
    function test_fullHappyPath() public {
        uint256 orderId = _buy(_list());

        vm.prank(seller);
        escrow.markDelivered(orderId);
        assertTrue(_status(orderId) == Escrow.Status.Delivered);

        vm.prank(buyer);
        escrow.confirmDelivery(orderId);
        assertTrue(_status(orderId) == Escrow.Status.Confirmed);
        assertEq(token.balanceOf(seller), 0); // not paid until redeem

        vm.prank(seller);
        escrow.redeem(orderId);
        assertTrue(_status(orderId) == Escrow.Status.Released);
        assertEq(token.balanceOf(seller), PRICE);
        assertEq(token.balanceOf(address(escrow)), 0);

        (, , , uint256 amount, , , uint256 confirmedAt, ) = escrow.orders(orderId);
        assertEq(amount, PRICE);
        assertGt(confirmedAt, 0);
    }

    function test_markDelivered_guards() public {
        uint256 orderId = _buy(_list());

        vm.prank(buyer);
        vm.expectRevert(Escrow.NotSellerError.selector);
        escrow.markDelivered(orderId);

        vm.startPrank(seller);
        escrow.markDelivered(orderId);
        vm.expectRevert(Escrow.WrongStatusError.selector);
        escrow.markDelivered(orderId);
        vm.stopPrank();
    }

    function test_confirmDelivery_guards() public {
        uint256 orderId = _buy(_list());

        vm.prank(buyer);
        vm.expectRevert(Escrow.WrongStatusError.selector); // not delivered yet
        escrow.confirmDelivery(orderId);

        vm.prank(seller);
        escrow.markDelivered(orderId);

        vm.prank(seller);
        vm.expectRevert(Escrow.NotBuyerError.selector);
        escrow.confirmDelivery(orderId);
    }

    function test_redeem_guards() public {
        uint256 orderId = _buy(_list());
        vm.prank(seller);
        escrow.markDelivered(orderId);

        vm.prank(seller);
        vm.expectRevert(Escrow.WrongStatusError.selector); // buyer hasn't confirmed
        escrow.redeem(orderId);

        vm.prank(buyer);
        escrow.confirmDelivery(orderId);

        vm.prank(buyer);
        vm.expectRevert(Escrow.NotSellerError.selector);
        escrow.redeem(orderId);

        vm.startPrank(seller);
        escrow.redeem(orderId);
        vm.expectRevert(Escrow.WrongStatusError.selector); // no double redeem
        escrow.redeem(orderId);
        vm.stopPrank();
    }

    // ---------- refund / dispute ----------
    function test_refundBeforeDelivery() public {
        uint256 before = token.balanceOf(buyer);
        uint256 orderId = _buy(_list());

        vm.prank(seller);
        vm.expectRevert(Escrow.NotBuyerError.selector);
        escrow.refundBeforeDelivery(orderId);

        vm.prank(buyer);
        escrow.refundBeforeDelivery(orderId);
        assertEq(token.balanceOf(buyer), before);
        assertTrue(_status(orderId) == Escrow.Status.Refunded);
    }

    function test_refund_notAllowedAfterDelivery() public {
        uint256 orderId = _buy(_list());
        vm.prank(seller);
        escrow.markDelivered(orderId);
        vm.prank(buyer);
        vm.expectRevert(Escrow.WrongStatusError.selector);
        escrow.refundBeforeDelivery(orderId);
    }

    function test_dispute_resolvedForSeller() public {
        uint256 orderId = _buy(_list());
        vm.prank(buyer);
        escrow.raiseDispute(orderId, "Item not as described");
        assertTrue(_status(orderId) == Escrow.Status.Disputed);

        vm.prank(gov);
        escrow.resolveDispute(orderId, true, "Seller delivered");
        assertEq(token.balanceOf(seller), PRICE);
        assertTrue(_status(orderId) == Escrow.Status.Released);
    }

    function test_dispute_resolvedForBuyer() public {
        uint256 before = token.balanceOf(buyer);
        uint256 orderId = _buy(_list());
        vm.prank(seller);
        escrow.raiseDispute(orderId, "Item not as described");

        vm.prank(gov);
        escrow.resolveDispute(orderId, false, "Refund approved");
        assertEq(token.balanceOf(buyer), before);
        assertTrue(_status(orderId) == Escrow.Status.Refunded);
    }

    function test_dispute_guards() public {
        uint256 orderId = _buy(_list());

        vm.prank(stranger);
        vm.expectRevert(Escrow.NotPartyError.selector);
        escrow.raiseDispute(orderId, "Item not as described");

        vm.prank(gov);
        vm.expectRevert(Escrow.WrongStatusError.selector); // not disputed
        escrow.resolveDispute(orderId, true, "Seller delivered");

        vm.prank(buyer);
        escrow.raiseDispute(orderId, "Item not as described");

        vm.prank(seller);
        vm.expectRevert(Escrow.OnlyGovernanceError.selector);
        escrow.resolveDispute(orderId, true, "Seller delivered");
    }

    // ---------- auto confirm ----------
    function test_claimAfterWindow() public {
        uint256 orderId = _buy(_list());
        vm.prank(seller);
        escrow.markDelivered(orderId);

        vm.prank(seller);
        vm.expectRevert(Escrow.WindowNotElapsedError.selector);
        escrow.claimAfterWindow(orderId);

        vm.warp(block.timestamp + 7 days);
        vm.prank(seller);
        escrow.claimAfterWindow(orderId);
        assertTrue(_status(orderId) == Escrow.Status.Confirmed);

        vm.prank(seller);
        escrow.redeem(orderId);
        assertEq(token.balanceOf(seller), PRICE);
    }

    function test_claimAfterWindow_onlySeller() public {
        uint256 orderId = _buy(_list());
        vm.prank(seller);
        escrow.markDelivered(orderId);
        vm.warp(block.timestamp + 8 days);
        vm.prank(buyer);
        vm.expectRevert(Escrow.NotSellerError.selector);
        escrow.claimAfterWindow(orderId);
    }

    // ---------- exchange (redemption to currency) ----------
    function _sellerHolds(uint256 amount) internal {
        vm.prank(gov);
        token.mint(seller, amount);
    }

    function _request(uint256 amount) internal returns (uint256 id) {
        vm.startPrank(seller);
        token.approve(address(escrow), amount);
        id = escrow.requestRedemption(amount, "NGN", "GTBank 0123456789");
        vm.stopPrank();
    }

    function test_requestRedemption_locksTokens() public {
        _sellerHolds(50e6);
        uint256 id = _request(20e6);
        assertEq(token.balanceOf(seller), 30e6);
        assertEq(token.balanceOf(address(escrow)), 20e6);
        (address s, uint256 amt, , Escrow.RedemptionStatus st, string memory cur, string memory det) = escrow.redemptions(id);
        assertEq(s, seller);
        assertEq(amt, 20e6);
        assertTrue(st == Escrow.RedemptionStatus.Pending);
        assertEq(cur, "NGN");
        assertEq(det, "GTBank 0123456789");
    }

    function test_requestRedemption_validations() public {
        _sellerHolds(5e6);
        vm.startPrank(seller);
        token.approve(address(escrow), 5e6);
        vm.expectRevert(Escrow.InvalidAmountError.selector);
        escrow.requestRedemption(0, "USD", "x");
        vm.expectRevert(Escrow.InvalidInputError.selector);
        escrow.requestRedemption(1e6, "", "x");
        vm.stopPrank();
    }

    function test_confirmRedemption_burnsTokens() public {
        _sellerHolds(50e6);
        uint256 id = _request(20e6);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(operator);
        escrow.confirmRedemption(id);

        assertEq(token.totalSupply(), supplyBefore - 20e6);
        assertEq(token.balanceOf(address(escrow)), 0);
        (, , , Escrow.RedemptionStatus st, , ) = escrow.redemptions(id);
        assertTrue(st == Escrow.RedemptionStatus.Completed);

        vm.prank(operator);
        vm.expectRevert(Escrow.WrongStatusError.selector);
        escrow.confirmRedemption(id);
    }

    function test_rejectRedemption_refundsSeller() public {
        _sellerHolds(50e6);
        uint256 id = _request(20e6);
        vm.prank(operator);
        escrow.rejectRedemption(id);
        assertEq(token.balanceOf(seller), 50e6);
        (, , , Escrow.RedemptionStatus st, , ) = escrow.redemptions(id);
        assertTrue(st == Escrow.RedemptionStatus.Rejected);
    }

    function test_redemption_onlyOperator() public {
        _sellerHolds(5e6);
        uint256 id = _request(5e6);
        vm.prank(stranger);
        vm.expectRevert(Escrow.OnlyOperatorError.selector);
        escrow.confirmRedemption(id);
        vm.prank(gov);
        vm.expectRevert(Escrow.OnlyOperatorError.selector);
        escrow.rejectRedemption(id);
    }

    function test_confirmRedemption_failsIfEscrowNotMinter() public {
        _sellerHolds(5e6);
        uint256 id = _request(5e6);
        vm.prank(gov);
        token.removeMinter(address(escrow));
        vm.prank(operator);
        vm.expectRevert(TCH8.OnlyMinterError.selector);
        escrow.confirmRedemption(id);
    }

    // ---------- escrow solvency ----------
    function test_escrowBalanceCoversOpenOrdersAndRedemptions() public {
        uint256 id = _list();
        _buy(id);
        _buy(id);
        _sellerHolds(7e6);
        _request(7e6);
        assertEq(token.balanceOf(address(escrow)), 2 * PRICE + 7e6);
    }

    // ---------- dispute reasons/replies and support tickets ----------
    function test_dispute_recordsReasonAndGovernanceReply() public {
        uint256 orderId = _buy(_list());
        vm.prank(buyer);
        escrow.raiseDispute(orderId, "Seller went silent");
        assertEq(escrow.disputeCount(), 1);
        assertEq(escrow.disputedOrderIds(0), orderId);

        (address by, uint256 at, uint256 doneAt, , string memory reason, string memory reply) = escrow.disputes(orderId);
        assertEq(by, buyer);
        assertEq(at, block.timestamp);
        assertEq(doneAt, 0);
        assertEq(reason, "Seller went silent");
        assertEq(reply, "");

        vm.prank(gov);
        escrow.resolveDispute(orderId, false, "Refund approved");
        (, , uint256 doneAt2, bool toSeller, , string memory reply2) = escrow.disputes(orderId);
        assertGt(doneAt2, 0);
        assertFalse(toSeller);
        assertEq(reply2, "Refund approved");
    }

    function test_dispute_requiresReasonAndReply() public {
        uint256 orderId = _buy(_list());
        vm.prank(buyer);
        vm.expectRevert(Escrow.InvalidInputError.selector);
        escrow.raiseDispute(orderId, "");

        vm.prank(buyer);
        escrow.raiseDispute(orderId, "Not received");

        vm.prank(gov);
        vm.expectRevert(Escrow.InvalidInputError.selector);
        escrow.resolveDispute(orderId, true, "");
    }

    function test_ticket_submitAndGovernanceReply() public {
        vm.prank(buyer);
        uint256 id = escrow.submitTicket(Escrow.TicketKind.Complaint, "Late delivery", "Order 0 is slow");
        assertEq(id, 0);
        assertEq(escrow.ticketCount(), 1);

        (address author, Escrow.TicketKind kind, , uint256 repliedAt, string memory subject, , string memory reply) = escrow.tickets(0);
        assertEq(author, buyer);
        assertTrue(kind == Escrow.TicketKind.Complaint);
        assertEq(repliedAt, 0);
        assertEq(subject, "Late delivery");
        assertEq(reply, "");

        vm.prank(gov);
        escrow.replyTicket(0, "We are checking it");
        (, , , uint256 repliedAt2, , , string memory reply2) = escrow.tickets(0);
        assertGt(repliedAt2, 0);
        assertEq(reply2, "We are checking it");
    }

    function test_ticket_guards() public {
        vm.startPrank(buyer);
        vm.expectRevert(Escrow.InvalidInputError.selector);
        escrow.submitTicket(Escrow.TicketKind.Enquiry, "", "body");
        vm.expectRevert(Escrow.InvalidInputError.selector);
        escrow.submitTicket(Escrow.TicketKind.Enquiry, "subject", "");
        escrow.submitTicket(Escrow.TicketKind.Enquiry, "How do I redeem?", "Please explain");
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(Escrow.OnlyGovernanceError.selector);
        escrow.replyTicket(0, "hi");

        vm.prank(gov);
        vm.expectRevert(Escrow.TicketNotFoundError.selector);
        escrow.replyTicket(5, "hi");

        vm.prank(gov);
        vm.expectRevert(Escrow.InvalidInputError.selector);
        escrow.replyTicket(0, "");
    }

    // ---------- optional image ----------
    function test_image_isOptional() public {
        vm.prank(seller);
        uint256 id = escrow.listItem("No photo", "", "", PRICE, 1);
        assertEq(escrow.itemImage(id), "");
    }

    function test_image_storesDataUriAndRejectsOversize() public {
        vm.prank(seller);
        uint256 id = escrow.listItem("Photo", "", "data:image/jpeg;base64,AAAA", PRICE, 1);
        assertEq(escrow.itemImage(id), "data:image/jpeg;base64,AAAA");

        string memory tooBig = string(new bytes(12001));
        vm.prank(seller);
        vm.expectRevert(Escrow.InvalidInputError.selector);
        escrow.listItem("Huge", "", tooBig, PRICE, 1);
    }

    // ---------- quantity ----------
    function _listQty(uint256 q) internal returns (uint256 id) {
        vm.prank(seller);
        id = escrow.listItem("Sneakers", "Size 42", "", PRICE, q);
    }

    function _qty(uint256 id) internal view returns (uint256 q) {
        (, , q, , , , ) = escrow.items(id);
    }

    function test_quantityOne_soldOutImmediatelyAfterPurchase() public {
        uint256 id = _list();
        _buy(id);
        assertEq(_qty(id), 0);

        vm.prank(gov);
        token.mint(stranger, 100e6);
        vm.startPrank(stranger);
        token.approve(address(escrow), PRICE);
        vm.expectRevert(Escrow.SoldOutError.selector);
        escrow.createOrder(id);
        vm.stopPrank();
    }

    function test_quantityTwo_dropsByOnePerPurchase() public {
        uint256 id = _listQty(2);
        _buy(id);
        assertEq(_qty(id), 1);
        _buy(id);
        assertEq(_qty(id), 0);
    }

    function test_refundBeforeDelivery_putsUnitBackOnSale() public {
        uint256 id = _list();
        uint256 orderId = _buy(id);
        assertEq(_qty(id), 0);
        vm.prank(buyer);
        escrow.refundBeforeDelivery(orderId);
        assertEq(_qty(id), 1);
    }

    function test_addStock_onlySellerAndRevivesSoldOut() public {
        uint256 id = _list();
        _buy(id);
        assertEq(_qty(id), 0);

        vm.prank(buyer);
        vm.expectRevert(Escrow.NotSellerError.selector);
        escrow.addStock(id, 3);

        vm.prank(seller);
        vm.expectRevert(Escrow.InvalidAmountError.selector);
        escrow.addStock(id, 0);

        vm.prank(seller);
        escrow.addStock(id, 3);
        assertEq(_qty(id), 3);
        _buy(id);
        assertEq(_qty(id), 2);
    }

    // ---------- admin ----------
    function test_admin_setters() public {
        vm.prank(gov);
        escrow.setAutoReleaseWindow(1 days);
        assertEq(escrow.autoReleaseWindow(), 1 days);

        vm.prank(gov);
        escrow.setOperator(stranger);
        assertEq(escrow.operator(), stranger);

        vm.prank(stranger);
        vm.expectRevert(Escrow.OnlyGovernanceError.selector);
        escrow.setAutoReleaseWindow(1);

        vm.prank(gov);
        vm.expectRevert(Escrow.ZeroAddressError.selector);
        escrow.setOperator(address(0));
    }

    function test_governanceTransfer_twoStep() public {
        vm.prank(gov);
        escrow.setGovernance(stranger);
        vm.prank(buyer);
        vm.expectRevert(Escrow.OnlyPendingGovernanceError.selector);
        escrow.acceptGovernance();
        vm.prank(stranger);
        escrow.acceptGovernance();
        assertEq(escrow.governance(), stranger);
    }

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(Escrow.ZeroAddressError.selector);
        new Escrow(address(0), gov, operator);
        vm.expectRevert(Escrow.ZeroAddressError.selector);
        new Escrow(address(token), address(0), operator);
        vm.expectRevert(Escrow.ZeroAddressError.selector);
        new Escrow(address(token), gov, address(0));
    }

    // ---------- end to end: buy TCH8 -> sell -> exchange ----------
    function test_endToEnd_confirmedThenExchange() public {
        uint256 orderId = _toConfirmed();
        vm.prank(seller);
        escrow.redeem(orderId);

        uint256 rid = _request(PRICE);
        vm.prank(operator);
        escrow.confirmRedemption(rid);

        assertEq(token.balanceOf(seller), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
    }
}
