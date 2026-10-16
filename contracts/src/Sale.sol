// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITCH8Mint {
    function mint(address recipient, uint256 amount) external;
}

/// @notice Users pay ETH and receive freshly minted TCH8.
/// priceWeiPerToken = wei required for ONE whole TCH8 (6 decimals).
contract Sale {
    error ZeroAddressError();
    error ZeroAmountError();
    error OnlyGovernanceError();
    error OnlyPendingGovernanceError();
    error WithdrawFailedError();

    struct Purchase {
        address buyer;
        uint256 ethPaid;
        uint256 tokensOut;
        uint256 time;
    }

    ITCH8Mint public immutable token;
    address public governance;
    address public pendingGovernance;
    uint256 public priceWeiPerToken;
    Purchase[] public purchases;

    event Purchased(address indexed buyer, uint256 ethPaid, uint256 tokensOut);
    event PriceUpdated(uint256 previousPrice, uint256 newPrice);
    event Withdrawn(address indexed to, uint256 amount);
    event GovernanceTransferStarted(address indexed previousGovernance, address indexed pendingGovernance);
    event GovernanceTransferAccepted(address indexed previousGovernance, address indexed newGovernance);

    modifier onlyGovernance() {
        if (msg.sender != governance) revert OnlyGovernanceError();
        _;
    }

    constructor(address _token, address _governance, uint256 _initialPriceWeiPerToken) {
        if (_token == address(0) || _governance == address(0)) revert ZeroAddressError();
        if (_initialPriceWeiPerToken == 0) revert ZeroAmountError();
        token = ITCH8Mint(_token);
        governance = _governance;
        priceWeiPerToken = _initialPriceWeiPerToken;
    }

    function buy() external payable {
        _buy();
    }

    receive() external payable {
        _buy();
    }

    function _buy() internal {
        if (msg.value == 0) revert ZeroAmountError();
        uint256 tokensOut = (msg.value * 1e6) / priceWeiPerToken;
        if (tokensOut == 0) revert ZeroAmountError();
        purchases.push(Purchase(msg.sender, msg.value, tokensOut, block.timestamp));
        token.mint(msg.sender, tokensOut);
        emit Purchased(msg.sender, msg.value, tokensOut);
    }

    function purchaseCount() external view returns (uint256) {
        return purchases.length;
    }

    function setPrice(uint256 newPriceWeiPerToken) external onlyGovernance {
        if (newPriceWeiPerToken == 0) revert ZeroAmountError();
        emit PriceUpdated(priceWeiPerToken, newPriceWeiPerToken);
        priceWeiPerToken = newPriceWeiPerToken;
    }

    function withdraw(address payable to, uint256 amount) external onlyGovernance {
        if (to == address(0)) revert ZeroAddressError();
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert WithdrawFailedError();
        emit Withdrawn(to, amount);
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
}
