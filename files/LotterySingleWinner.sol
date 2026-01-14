// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@pythnetwork/entropy-sdk-solidity/IEntropy.sol";

interface IEntropyConsumer {
    function entropyCallback(uint64 sequenceNumber, address provider, bytes32 randomNumber) external;
}

/**
 * @title LotterySingleWinner (Mainnet Candidate v1.6)
 * @notice A single-winner lottery instance using Pyth Entropy.
 * @dev Updated: explicit cancel snapshot + native surplus sweep + stricter funding check.
 */
contract LotterySingleWinner is Ownable, IEntropyConsumer, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    struct LotteryParams {
        address usdcToken;
        address entropy;
        address entropyProvider;
        address feeRecipient;
        uint256 protocolFeePercent;
        address creator;
        string name;
        uint256 ticketPrice;
        uint256 winningPot;
        uint64 minTickets;
        uint64 maxTickets;
        uint64 durationSeconds;
        uint32 minPurchaseAmount;
    }

    // Errors
    error InvalidEntropy();
    error InvalidProvider();
    error InvalidUSDC();
    error InvalidFeeRecipient();
    error InvalidCreator();
    error FeeTooHigh();
    error NameEmpty();
    error DurationTooShort();
    error DurationTooLong();
    error InvalidPrice();
    error InvalidPot();
    error InvalidMinTickets();
    error MaxLessThanMin();
    error BatchTooCheap();

    error NotDeployer();
    error NotFundingPending();
    error FundingMismatch();

    error LotteryNotOpen();
    error LotteryExpired();
    error TicketLimitReached();
    error CreatorCannotBuy();
    error InvalidCount();
    error BatchTooLarge();
    error BatchTooSmall();
    error TooManyRanges();
    error Overflow();

    error RequestPending();
    error NotReadyToFinalize();
    error NoParticipants();
    error InsufficientFee();
    error InvalidRequest();

    error UnauthorizedCallback();

    error NotDrawing();
    error CannotCancel();
    error NotCanceled();
    error EarlyCancellationRequest();
    error EmergencyHatchLocked();

    error NothingToClaim();
    error NothingToRefund();
    error NativeRefundFailed();
    error ZeroAddress();
    error NoSurplus();
    error NoNativeSurplus();
    error DrawingsActive();
    error AccountingMismatch();
    error UnexpectedTransferAmount();

    // Events
    event CallbackRejected(uint64 indexed sequenceNumber, uint8 reasonCode);
    event TicketsPurchased(
        address indexed buyer,
        uint256 count,
        uint256 totalCost,
        uint256 totalSold,
        uint256 rangeIndex,
        bool isNewRange
    );
    event LotteryFinalized(uint64 requestId, uint256 totalSold, address provider);
    event WinnerPicked(address indexed winner, uint256 winningTicketIndex, uint256 totalSold);
    event LotteryCanceled(string reason, uint256 sold, uint256 ticketRevenue, uint256 potRefund);
    event EmergencyRecovery();
    event RefundAllocated(address indexed user, uint256 amount);
    event FundsClaimed(address indexed user, uint256 amount);
    event NativeRefundAllocated(address indexed user, uint256 amount);
    event NativeClaimed(address indexed user, uint256 amount);
    event ProtocolFeesCollected(uint256 amount);
    event EntropyProviderUpdated(address newProvider);
    event EntropyContractUpdated(address newContract);
    event GovernanceLockUpdated(uint256 activeDrawings);
    event PrizeAllocated(address indexed user, uint256 amount, uint8 indexed reason);
    event FundingConfirmed(address indexed funder, uint256 amount);
    event SurplusSwept(address indexed to, uint256 amount);
    event NativeSurplusSwept(address indexed to, uint256 amount);

    // State
    IERC20 public immutable usdcToken;
    address public immutable creator;
    address public immutable feeRecipient;
    uint256 public immutable protocolFeePercent;
    address public immutable deployer;

    IEntropy public entropy;
    address public entropyProvider;

    uint256 public constant MAX_BATCH_BUY = 1000;
    uint256 public constant MAX_RANGES = 20_000;
    uint256 public constant MIN_NEW_RANGE_COST = 1_000_000;
    uint256 public constant MAX_TICKET_PRICE = 100_000 * 1e6;
    uint256 public constant MAX_POT_SIZE = 10_000_000 * 1e6;
    uint64 public constant MAX_DURATION = 365 days;
    uint256 public constant PRIVILEGED_HATCH_DELAY = 1 days;
    uint256 public constant PUBLIC_HATCH_DELAY = 7 days;
    uint256 public constant HARD_CAP_TICKETS = 10_000_000;

    /**
     * Accounting (USDC):
     * - totalReservedUSDC tracks liabilities that must remain in-contract.
     * - Initially: winningPot (after confirmFunding)
     * - Each ticket purchase: +totalCost
     * - Each withdrawal of USDC claimable: -amount
     */
    uint256 public totalReservedUSDC;

    /**
     * Accounting (Native):
     * - totalClaimableNative is the sum of claimableNative across all users.
     * - Used to safely sweep accidental native deposits.
     */
    uint256 public totalClaimableNative;

    uint256 public activeDrawings;

    enum Status {
        FundingPending,
        Open,
        Drawing,
        Completed,
        Canceled
    }
    Status public status;

    string public name;
    uint64 public createdAt;
    uint64 public deadline;

    uint256 public ticketPrice;
    uint256 public winningPot;
    uint256 public ticketRevenue;

    uint64 public minTickets;
    uint64 public maxTickets;
    uint32 public minPurchaseAmount;

    address public winner;
    address public selectedProvider;
    uint64 public drawingRequestedAt;
    uint64 public entropyRequestId;
    uint256 public soldAtDrawing;

    // Cancel snapshot (explicit, for clarity + indexing safety)
    uint256 public soldAtCancel;
    uint64 public canceledAt;

    struct TicketRange {
        address buyer;
        uint96 upperBound;
    }

    TicketRange[] public ticketRanges;
    mapping(address => uint256) public ticketsOwned;
    mapping(address => uint256) public claimableFunds;
    mapping(address => uint256) public claimableNative;
    bool public creatorPotRefunded;

    constructor(LotteryParams memory params) Ownable(msg.sender) {
        deployer = msg.sender;

        if (params.entropy == address(0)) revert InvalidEntropy();
        if (params.usdcToken == address(0)) revert InvalidUSDC();
        if (params.entropyProvider == address(0)) revert InvalidProvider();
        if (params.feeRecipient == address(0)) revert InvalidFeeRecipient();
        if (params.creator == address(0)) revert InvalidCreator();

        // Fee Verification: Integer percent (0-20)
        if (params.protocolFeePercent > 20) revert FeeTooHigh();

        try IERC20Metadata(params.usdcToken).decimals() returns (uint8 d) {
            if (d != 6) revert InvalidUSDC();
        } catch {
            revert InvalidUSDC();
        }

        if (bytes(params.name).length == 0) revert NameEmpty();
        if (params.durationSeconds < 600) revert DurationTooShort();
        if (params.durationSeconds > MAX_DURATION) revert DurationTooLong();
        if (params.ticketPrice == 0 || params.ticketPrice > MAX_TICKET_PRICE) revert InvalidPrice();
        if (params.winningPot == 0 || params.winningPot > MAX_POT_SIZE) revert InvalidPot();
        if (params.minTickets == 0) revert InvalidMinTickets();
        if (params.minPurchaseAmount > MAX_BATCH_BUY) revert BatchTooLarge();
        if (params.maxTickets != 0 && params.maxTickets < params.minTickets) revert MaxLessThanMin();

        uint256 minEntry = (params.minPurchaseAmount == 0) ? 1 : uint256(params.minPurchaseAmount);
        uint256 requiredMinPrice = (MIN_NEW_RANGE_COST + minEntry - 1) / minEntry;
        if (params.ticketPrice < requiredMinPrice) revert BatchTooCheap();

        usdcToken = IERC20(params.usdcToken);
        entropy = IEntropy(params.entropy);
        entropyProvider = params.entropyProvider;
        feeRecipient = params.feeRecipient;
        protocolFeePercent = params.protocolFeePercent;
        creator = params.creator;

        name = params.name;
        createdAt = uint64(block.timestamp);
        deadline = uint64(block.timestamp + params.durationSeconds);

        ticketPrice = params.ticketPrice;
        winningPot = params.winningPot;
        minTickets = params.minTickets;
        maxTickets = params.maxTickets;
        minPurchaseAmount = params.minPurchaseAmount;

        status = Status.FundingPending;
    }

    function confirmFunding() external {
        if (msg.sender != deployer) revert NotDeployer();
        if (status != Status.FundingPending) revert NotFundingPending();

        uint256 bal = usdcToken.balanceOf(address(this));

        // Accept >= to avoid bricking the lottery if any dust is sent pre-confirmation.
        if (bal < winningPot) revert FundingMismatch();

        totalReservedUSDC = winningPot;
        status = Status.Open;

        emit FundingConfirmed(msg.sender, winningPot);
    }

    function buyTickets(uint256 count) external nonReentrant whenNotPaused {
        if (status != Status.Open) revert LotteryNotOpen();

        if (count == 0) revert InvalidCount();
        if (count > MAX_BATCH_BUY) revert BatchTooLarge();

        if (block.timestamp >= deadline) revert LotteryExpired();
        if (msg.sender == creator) revert CreatorCannotBuy();
        if (minPurchaseAmount > 0 && count < minPurchaseAmount) revert BatchTooSmall();

        uint256 currentSold = getSold();
        uint256 newTotal = currentSold + count;

        if (newTotal > type(uint96).max) revert Overflow();

        if (newTotal > HARD_CAP_TICKETS) revert TicketLimitReached();
        if (maxTickets > 0 && newTotal > maxTickets) revert TicketLimitReached();

        uint256 totalCost = ticketPrice * count;

        bool returning =
            (ticketRanges.length > 0 && ticketRanges[ticketRanges.length - 1].buyer == msg.sender);

        if (!returning) {
            if (ticketRanges.length >= MAX_RANGES) revert TooManyRanges();
            if (totalCost < MIN_NEW_RANGE_COST) revert BatchTooCheap();
        }

        // Effects
        uint256 rangeIndex;
        bool isNewRange;

        if (returning) {
            rangeIndex = ticketRanges.length - 1;
            isNewRange = false;
            ticketRanges[rangeIndex].upperBound = uint96(newTotal);
        } else {
            ticketRanges.push(TicketRange({buyer: msg.sender, upperBound: uint96(newTotal)}));
            rangeIndex = ticketRanges.length - 1;
            isNewRange = true;
        }

        totalReservedUSDC += totalCost;
        ticketRevenue += totalCost;
        ticketsOwned[msg.sender] += count;

        emit TicketsPurchased(msg.sender, count, totalCost, newTotal, rangeIndex, isNewRange);

        // Interactions + balance delta check
        uint256 balBefore = usdcToken.balanceOf(address(this));
        usdcToken.safeTransferFrom(msg.sender, address(this), totalCost);
        uint256 balAfter = usdcToken.balanceOf(address(this));

        if (balAfter < balBefore + totalCost) revert UnexpectedTransferAmount();
    }

    function finalize() external payable nonReentrant whenNotPaused {
        if (status != Status.Open) revert LotteryNotOpen();
        if (entropyRequestId != 0) revert RequestPending();

        uint256 sold = getSold();
        bool isFull = (maxTickets > 0 && sold >= maxTickets);
        bool isExpired = (block.timestamp >= deadline);

        if (!isFull && !isExpired) revert NotReadyToFinalize();

        if (isExpired && sold < minTickets) {
            _cancelAndRefundCreator("Min tickets not reached");
            if (msg.value > 0) _safeNativeTransfer(msg.sender, msg.value);
            return;
        }

        if (sold == 0) revert NoParticipants();

        status = Status.Drawing;
        soldAtDrawing = sold;
        drawingRequestedAt = uint64(block.timestamp);
        selectedProvider = entropyProvider;
        activeDrawings += 1;
        emit GovernanceLockUpdated(activeDrawings);

        uint256 fee = entropy.getFee(entropyProvider);
        if (msg.value < fee) revert InsufficientFee();

        uint64 requestId = entropy.requestWithCallback{value: fee}(
            entropyProvider,
            keccak256(abi.encodePacked(address(this), block.prevrandao, block.timestamp))
        );
        if (requestId == 0) revert InvalidRequest();

        entropyRequestId = requestId;

        if (msg.value > fee) {
            _safeNativeTransfer(msg.sender, msg.value - fee);
        }

        emit LotteryFinalized(requestId, sold, entropyProvider);
    }

    function entropyCallback(uint64 sequenceNumber, address provider, bytes32 randomNumber) external override {
        if (msg.sender != address(entropy)) revert UnauthorizedCallback();

        if (entropyRequestId == 0 || sequenceNumber != entropyRequestId) {
            emit CallbackRejected(sequenceNumber, 1);
            return;
        }
        if (status != Status.Drawing || provider != selectedProvider) {
            emit CallbackRejected(sequenceNumber, 2);
            return;
        }

        _resolve(randomNumber);
    }

    function _resolve(bytes32 rand) internal {
        uint256 total = soldAtDrawing;
        if (total == 0) revert NoParticipants();

        // Clear drawing state first
        entropyRequestId = 0;
        soldAtDrawing = 0;
        drawingRequestedAt = 0;
        selectedProvider = address(0);

        if (activeDrawings > 0) activeDrawings -= 1;
        emit GovernanceLockUpdated(activeDrawings);

        uint256 winningIndex = uint256(rand) % total;
        address w = _findWinner(winningIndex);

        winner = w;
        status = Status.Completed;

        uint256 feePot = (winningPot * protocolFeePercent) / 100;
        uint256 feeRev = (ticketRevenue * protocolFeePercent) / 100;

        uint256 winnerAmount = winningPot - feePot;
        uint256 creatorNet = ticketRevenue - feeRev;
        uint256 protocolAmount = feePot + feeRev;

        claimableFunds[w] += winnerAmount;
        emit PrizeAllocated(w, winnerAmount, 1);

        if (creatorNet > 0) {
            claimableFunds[creator] += creatorNet;
            emit PrizeAllocated(creator, creatorNet, 2);
        }

        if (protocolAmount > 0) {
            claimableFunds[feeRecipient] += protocolAmount;
            emit PrizeAllocated(feeRecipient, protocolAmount, 4);
        }

        emit WinnerPicked(w, winningIndex, total);
        emit ProtocolFeesCollected(protocolAmount);
    }

    function _findWinner(uint256 winningTicket) internal view returns (address) {
        uint256 low = 0;
        uint256 high = ticketRanges.length - 1;

        while (low < high) {
            uint256 mid = low + (high - low) / 2;
            if (ticketRanges[mid].upperBound > winningTicket) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        return ticketRanges[low].buyer;
    }

    function forceCancelStuck() external nonReentrant {
        if (status != Status.Drawing) revert NotDrawing();

        bool privileged = (msg.sender == owner() || msg.sender == creator);
        if (privileged) {
            if (block.timestamp <= drawingRequestedAt + PRIVILEGED_HATCH_DELAY) revert EarlyCancellationRequest();
        } else {
            if (block.timestamp <= drawingRequestedAt + PUBLIC_HATCH_DELAY) revert EmergencyHatchLocked();
        }

        emit EmergencyRecovery();
        _cancelAndRefundCreator("Emergency Recovery");
    }

    function cancel() external nonReentrant {
        if (status != Status.Open) revert CannotCancel();
        if (block.timestamp < deadline) revert CannotCancel();
        if (getSold() >= minTickets) revert CannotCancel();
        _cancelAndRefundCreator("Min tickets not reached");
    }

    function _cancelAndRefundCreator(string memory reason) internal {
        if (status == Status.Canceled) return;

        // Snapshot sold before any state changes (explicit + indexer friendly)
        uint256 soldSnapshot = getSold();
        soldAtCancel = soldSnapshot;
        canceledAt = uint64(block.timestamp);

        bool wasDrawing = (status == Status.Drawing);

        status = Status.Canceled;

        // Clean up drawing state (if any)
        selectedProvider = address(0);
        drawingRequestedAt = 0;
        entropyRequestId = 0;
        soldAtDrawing = 0;

        if (wasDrawing && activeDrawings > 0) {
            activeDrawings -= 1;
            emit GovernanceLockUpdated(activeDrawings);
        }

        // Pot refund to creator (once)
        uint256 potRefund = 0;
        if (!creatorPotRefunded && winningPot > 0) {
            creatorPotRefunded = true;
            potRefund = winningPot;

            // Note: totalReservedUSDC already includes winningPot from confirmFunding.
            claimableFunds[creator] += winningPot;
            emit PrizeAllocated(creator, winningPot, 5);
            emit RefundAllocated(creator, winningPot);
        }

        emit LotteryCanceled(reason, soldSnapshot, ticketRevenue, potRefund);
    }

    function claimTicketRefund() external nonReentrant {
        if (status != Status.Canceled) revert NotCanceled();

        uint256 tix = ticketsOwned[msg.sender];
        if (tix == 0) revert NothingToRefund();

        uint256 refund = tix * ticketPrice;

        // Effects
        ticketsOwned[msg.sender] = 0;

        // Note: totalReservedUSDC already includes ticket revenue from purchases.
        claimableFunds[msg.sender] += refund;
        emit PrizeAllocated(msg.sender, refund, 3);
        emit RefundAllocated(msg.sender, refund);
    }

    function withdrawFunds() external nonReentrant {
        uint256 amount = claimableFunds[msg.sender];
        if (amount == 0) revert NothingToClaim();

        // Effects
        claimableFunds[msg.sender] = 0;

        // Accounting
        if (totalReservedUSDC < amount) revert AccountingMismatch();
        totalReservedUSDC -= amount;

        // Interaction
        usdcToken.safeTransfer(msg.sender, amount);
        emit FundsClaimed(msg.sender, amount);
    }

    function _safeNativeTransfer(address to, uint256 amount) internal {
        (bool success,) = payable(to).call{value: amount}("");
        if (!success) {
            claimableNative[to] += amount;
            totalClaimableNative += amount;
            emit NativeRefundAllocated(to, amount);
        }
    }

    function withdrawNative() external nonReentrant {
        withdrawNativeTo(msg.sender);
    }

    /// @notice Withdraw native claimable to a specified address (helps contract wallets that can't receive native).
    function withdrawNativeTo(address to) public nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        uint256 amount = claimableNative[msg.sender];
        if (amount == 0) revert NothingToClaim();

        if (totalClaimableNative < amount) revert AccountingMismatch();

        // Effects
        claimableNative[msg.sender] = 0;
        totalClaimableNative -= amount;

        // Interaction
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert NativeRefundFailed();

        emit NativeClaimed(msg.sender, amount);
    }

    function sweepSurplus(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        uint256 currentBalance = usdcToken.balanceOf(address(this));
        if (currentBalance <= totalReservedUSDC) revert NoSurplus();

        uint256 surplus = currentBalance - totalReservedUSDC;
        usdcToken.safeTransfer(to, surplus);
        emit SurplusSwept(to, surplus);
    }

    /**
     * @notice Sweep accidental native deposits while protecting user claimables.
     * @dev Surplus = address(this).balance - totalClaimableNative
     */
    function sweepNativeSurplus(address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();

        uint256 bal = address(this).balance;
        if (bal <= totalClaimableNative) revert NoNativeSurplus();

        uint256 surplus = bal - totalClaimableNative;
        (bool ok,) = payable(to).call{value: surplus}("");
        if (!ok) revert NativeRefundFailed();

        emit NativeSurplusSwept(to, surplus);
    }

    function setEntropyProvider(address p) external onlyOwner {
        if (p == address(0)) revert InvalidProvider();
        if (activeDrawings != 0) revert DrawingsActive();
        entropyProvider = p;
        emit EntropyProviderUpdated(p);
    }

    function setEntropyContract(address e) external onlyOwner {
        if (e == address(0)) revert InvalidEntropy();
        if (activeDrawings != 0) revert DrawingsActive();
        entropy = IEntropy(e);
        emit EntropyContractUpdated(e);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function getSold() public view returns (uint256) {
        uint256 len = ticketRanges.length;
        return len == 0 ? 0 : ticketRanges[len - 1].upperBound;
    }

    receive() external payable {}
}