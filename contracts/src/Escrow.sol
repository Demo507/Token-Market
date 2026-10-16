// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ITCH8Burn {
    function burn(uint256 amount) external;
}

/// @notice Marketplace + escrow.
/// Flow: listItem -> buyer createOrder (TCH8 buyer->escrow) -> seller markDelivered
///       -> buyer confirmDelivery -> seller redeem (TCH8 escrow->seller wallet)
///       -> seller requestRedemption (exchange to a currency; operator confirms and TCH8 is burned).
contract Escrow is ReentrancyGuard {
    error ZeroAddressError();
    error InvalidAmountError();
    error InvalidInputError();
    error NotBuyerError();
    error NotSellerError();
    error NotPartyError();
    error WrongStatusError();
    error TransferFailedError();
    error OnlyGovernanceError();
    error OnlyPendingGovernanceError();
    error OnlyOperatorError();
    error SelfPurchaseError();
    error ItemInactiveError();
    error ItemNotFoundError();
    error SoldOutError();
    error TicketNotFoundError();
    error WindowNotElapsedError();

    enum Status { None, Paid, Delivered, Confirmed, Released, Refunded, Disputed }
    enum RedemptionStatus { None, Pending, Completed, Rejected }

    struct Item {
        address seller;
        uint256 price;
        uint256 quantity; // units still in stock; item disappears from the market at 0
        bool active;
        uint256 createdAt;
        string title;
        string description;
        // image lives in itemImage[itemId] so reading the list stays cheap
    }

    struct Order {
        uint256 itemId;
        address buyer;
        address seller;
        uint256 amount;
        uint256 createdAt;
        uint256 deliveredAt;
        uint256 confirmedAt;
        Status status;
    }

    struct Redemption {
        address seller;
        uint256 amount;
        uint256 createdAt;
        RedemptionStatus status;
        string currency;
        string details;
    }

    enum TicketKind { Complaint, Enquiry }

    struct Ticket {
        address author;
        TicketKind kind;
        uint256 createdAt;
        uint256 repliedAt; // 0 = not answered yet
        string subject;
        string message;
        string reply;
    }

    struct DisputeInfo {
        address raisedBy;
        uint256 raisedAt;
        uint256 resolvedAt; // 0 = still open
        bool releasedToSeller;
        string reason;
        string reply; // governance explanation
    }

    IERC20 public immutable token;
    uint256 public autoReleaseWindow = 7 days;

    Item[] public items;
    mapping(uint256 => string) public itemImage; // optional: image link or small data:image/jpeg URI
    Order[] public orders;
    Redemption[] public redemptions;
    Ticket[] public tickets;
    mapping(uint256 => DisputeInfo) public disputes; // by orderId
    uint256[] public disputedOrderIds;

    address public governance;
    address public pendingGovernance;
    address public operator;

    event ItemListed(uint256 indexed itemId, address indexed seller, uint256 price, uint256 quantity);
    event StockAdded(uint256 indexed itemId, uint256 added, uint256 remaining);
    event ItemActiveChanged(uint256 indexed itemId, bool active);
    event OrderCreated(uint256 indexed orderId, uint256 indexed itemId, address indexed buyer, address seller, uint256 amount);
    event Delivered(uint256 indexed orderId);
    event Confirmed(uint256 indexed orderId);
    event Released(uint256 indexed orderId, address indexed to, uint256 amount);
    event Refunded(uint256 indexed orderId, address indexed to, uint256 amount);
    event Disputed(uint256 indexed orderId);
    event DisputeResolved(uint256 indexed orderId, bool releasedToSeller);
    event GovernanceTransferStarted(address indexed previousGovernance, address indexed pendingGovernance);
    event GovernanceTransferAccepted(address indexed previousGovernance, address indexed newGovernance);
    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event RedemptionRequested(uint256 indexed redemptionId, address indexed seller, uint256 amount, string currency);
    event RedemptionCompleted(uint256 indexed redemptionId, address indexed seller, uint256 amount);
    event RedemptionRejected(uint256 indexed redemptionId, address indexed seller, uint256 amount);
    event TicketSubmitted(uint256 indexed ticketId, address indexed author, TicketKind kind);
    event TicketReplied(uint256 indexed ticketId);

    modifier onlyGovernance() {
        if (msg.sender != governance) revert OnlyGovernanceError();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert OnlyOperatorError();
        _;
    }

    constructor(address _token, address _governance, address _operator) {
        if (_token == address(0) || _governance == address(0) || _operator == address(0)) revert ZeroAddressError();
        token = IERC20(_token);
        governance = _governance;
        operator = _operator;
    }

    // ---------- views ----------
    function itemCount() external view returns (uint256) { return items.length; }
    function orderCount() external view returns (uint256) { return orders.length; }
    function redemptionCount() external view returns (uint256) { return redemptions.length; }
    function disputeCount() external view returns (uint256) { return disputedOrderIds.length; }
    function ticketCount() external view returns (uint256) { return tickets.length; }

    // ---------- listings (anyone can list) ----------
    function listItem(
        string calldata title,
        string calldata description,
        string calldata image,
        uint256 price,
        uint256 quantity
    ) external returns (uint256 itemId) {
        if (price == 0 || quantity == 0) revert InvalidAmountError();
        if (bytes(title).length == 0 || bytes(title).length > 120) revert InvalidInputError();
        if (bytes(description).length > 1000 || bytes(image).length > 12000) revert InvalidInputError();
        itemId = items.length;
        items.push(Item(msg.sender, price, quantity, true, block.timestamp, title, description));
        if (bytes(image).length > 0) itemImage[itemId] = image;
        emit ItemListed(itemId, msg.sender, price, quantity);
    }

    function setItemActive(uint256 itemId, bool active) external {
        if (itemId >= items.length) revert ItemNotFoundError();
        if (items[itemId].seller != msg.sender) revert NotSellerError();
        items[itemId].active = active;
        emit ItemActiveChanged(itemId, active);
    }

    /// @notice Seller adds more units to an existing listing (also revives a sold-out item).
    function addStock(uint256 itemId, uint256 extra) external {
        if (itemId >= items.length) revert ItemNotFoundError();
        Item storage it = items[itemId];
        if (it.seller != msg.sender) revert NotSellerError();
        if (extra == 0) revert InvalidAmountError();
        it.quantity += extra;
        emit StockAdded(itemId, extra, it.quantity);
    }

    // ---------- orders ----------
    /// @notice Buyer signs: TCH8 moves buyer -> escrow. Buyer must approve this contract first.
    function createOrder(uint256 itemId) external nonReentrant returns (uint256 orderId) {
        if (itemId >= items.length) revert ItemNotFoundError();
        Item storage it = items[itemId];
        if (!it.active) revert ItemInactiveError();
        if (it.quantity == 0) revert SoldOutError();
        if (msg.sender == it.seller) revert SelfPurchaseError();

        uint256 amount = it.price;
        it.quantity -= 1; // one unit per order; 0 left = off the market
        orderId = orders.length;
        orders.push(Order(itemId, msg.sender, it.seller, amount, block.timestamp, 0, 0, Status.Paid));
        emit OrderCreated(orderId, itemId, msg.sender, it.seller, amount);

        if (!token.transferFrom(msg.sender, address(this), amount)) revert TransferFailedError();
    }

    function markDelivered(uint256 orderId) external {
        Order storage o = orders[orderId];
        if (msg.sender != o.seller) revert NotSellerError();
        if (o.status != Status.Paid) revert WrongStatusError();
        o.status = Status.Delivered;
        o.deliveredAt = block.timestamp;
        emit Delivered(orderId);
    }

    function confirmDelivery(uint256 orderId) external {
        Order storage o = orders[orderId];
        if (msg.sender != o.buyer) revert NotBuyerError();
        if (o.status != Status.Delivered) revert WrongStatusError();
        o.status = Status.Confirmed;
        o.confirmedAt = block.timestamp;
        emit Confirmed(orderId);
    }

    /// @notice If the buyer never confirms, the seller can confirm after the window.
    function claimAfterWindow(uint256 orderId) external {
        Order storage o = orders[orderId];
        if (msg.sender != o.seller) revert NotSellerError();
        if (o.status != Status.Delivered) revert WrongStatusError();
        if (block.timestamp < o.deliveredAt + autoReleaseWindow) revert WindowNotElapsedError();
        o.status = Status.Confirmed;
        o.confirmedAt = block.timestamp;
        emit Confirmed(orderId);
    }

    /// @notice Seller redeems confirmed order: TCH8 escrow -> seller wallet.
    function redeem(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        if (msg.sender != o.seller) revert NotSellerError();
        if (o.status != Status.Confirmed) revert WrongStatusError();
        _release(orderId, o);
    }

    function refundBeforeDelivery(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        if (msg.sender != o.buyer) revert NotBuyerError();
        if (o.status != Status.Paid) revert WrongStatusError();
        items[o.itemId].quantity += 1; // never shipped, so the unit goes back on sale
        _refund(orderId, o);
    }

    /// @notice Buyer or seller lodges a dispute with a written reason. Funds stay frozen in escrow.
    function raiseDispute(uint256 orderId, string calldata reason) external {
        Order storage o = orders[orderId];
        if (msg.sender != o.buyer && msg.sender != o.seller) revert NotPartyError();
        if (o.status != Status.Paid && o.status != Status.Delivered) revert WrongStatusError();
        if (bytes(reason).length == 0 || bytes(reason).length > 1000) revert InvalidInputError();
        o.status = Status.Disputed;
        disputes[orderId] = DisputeInfo(msg.sender, block.timestamp, 0, false, reason, "");
        disputedOrderIds.push(orderId);
        emit Disputed(orderId);
    }

    /// @notice Governance decides (pay seller or refund buyer) and must give a written reply.
    function resolveDispute(uint256 orderId, bool releaseToSeller, string calldata reply) external onlyGovernance nonReentrant {
        Order storage o = orders[orderId];
        if (o.status != Status.Disputed) revert WrongStatusError();
        if (bytes(reply).length == 0 || bytes(reply).length > 1000) revert InvalidInputError();
        DisputeInfo storage d = disputes[orderId];
        d.resolvedAt = block.timestamp;
        d.releasedToSeller = releaseToSeller;
        d.reply = reply;
        emit DisputeResolved(orderId, releaseToSeller);
        if (releaseToSeller) _release(orderId, o);
        else _refund(orderId, o);
    }

    // ---------- exchange (TCH8 -> any currency, paid by operator off-chain) ----------
    function requestRedemption(uint256 amount, string calldata currency, string calldata details)
        external
        nonReentrant
        returns (uint256 redemptionId)
    {
        if (amount == 0) revert InvalidAmountError();
        if (bytes(currency).length == 0 || bytes(currency).length > 20) revert InvalidInputError();
        if (bytes(details).length > 300) revert InvalidInputError();
        redemptionId = redemptions.length;
        redemptions.push(Redemption(msg.sender, amount, block.timestamp, RedemptionStatus.Pending, currency, details));
        emit RedemptionRequested(redemptionId, msg.sender, amount, currency);
        if (!token.transferFrom(msg.sender, address(this), amount)) revert TransferFailedError();
    }

    function confirmRedemption(uint256 redemptionId) external onlyOperator nonReentrant {
        Redemption storage r = redemptions[redemptionId];
        if (r.status != RedemptionStatus.Pending) revert WrongStatusError();
        r.status = RedemptionStatus.Completed;
        ITCH8Burn(address(token)).burn(r.amount);
        emit RedemptionCompleted(redemptionId, r.seller, r.amount);
    }

    function rejectRedemption(uint256 redemptionId) external onlyOperator nonReentrant {
        Redemption storage r = redemptions[redemptionId];
        if (r.status != RedemptionStatus.Pending) revert WrongStatusError();
        r.status = RedemptionStatus.Rejected;
        if (!token.transfer(r.seller, r.amount)) revert TransferFailedError();
        emit RedemptionRejected(redemptionId, r.seller, r.amount);
    }

    // ---------- complaints and enquiries ----------
    function submitTicket(TicketKind kind, string calldata subject, string calldata message) external returns (uint256 ticketId) {
        if (bytes(subject).length == 0 || bytes(subject).length > 120) revert InvalidInputError();
        if (bytes(message).length == 0 || bytes(message).length > 1000) revert InvalidInputError();
        ticketId = tickets.length;
        tickets.push(Ticket(msg.sender, kind, block.timestamp, 0, subject, message, ""));
        emit TicketSubmitted(ticketId, msg.sender, kind);
    }

    function replyTicket(uint256 ticketId, string calldata reply) external onlyGovernance {
        if (ticketId >= tickets.length) revert TicketNotFoundError();
        if (bytes(reply).length == 0 || bytes(reply).length > 1000) revert InvalidInputError();
        Ticket storage t = tickets[ticketId];
        t.reply = reply;
        t.repliedAt = block.timestamp;
        emit TicketReplied(ticketId);
    }

    // ---------- admin ----------
    function setAutoReleaseWindow(uint256 newWindow) external onlyGovernance {
        autoReleaseWindow = newWindow;
    }

    function setGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert ZeroAddressError();
        pendingGovernance = newGovernance;
        emit GovernanceTransferStarted(governance, newGovernance);
    }

    function acceptGovernance() external {
        if (msg.sender != pendingGovernance) revert OnlyPendingGovernanceError();
        emit GovernanceTransferAccepted(governance, pendingGovernance);
        governance = pendingGovernance;
        pendingGovernance = address(0);
    }

    function setOperator(address newOperator) external onlyGovernance {
        if (newOperator == address(0)) revert ZeroAddressError();
        emit OperatorUpdated(operator, newOperator);
        operator = newOperator;
    }

    // ---------- internal ----------
    function _release(uint256 orderId, Order storage o) internal {
        o.status = Status.Released;
        if (o.confirmedAt == 0) o.confirmedAt = block.timestamp;
        if (!token.transfer(o.seller, o.amount)) revert TransferFailedError();
        emit Released(orderId, o.seller, o.amount);
    }

    function _refund(uint256 orderId, Order storage o) internal {
        o.status = Status.Refunded;
        if (!token.transfer(o.buyer, o.amount)) revert TransferFailedError();
        emit Refunded(orderId, o.buyer, o.amount);
    }
}
