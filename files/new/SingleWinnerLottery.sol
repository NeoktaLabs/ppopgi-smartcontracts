// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@pythnetwork/entropy-sdk-solidity/IEntropyV2.sol";

/**
 * @title SingleWinnerLottery
 * @notice Single-winner lottery with Entropy (Pyth) randomness.
 *
 * Governance model: NONE.
 * - No owner, no admin setters, no pause, no sweeping.
 * - All configuration is immutable after deployment.
 * - If something goes wrong upstream (entropy/provider/gas), the mitigation is redeploy.
 */
contract SingleWinnerLottery is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------- Types ----------
    struct LotteryParams {
        address usdcToken;
        address entropy;            // Entropy contract (v2)
        address entropyProvider;    // provider address (usually default provider)
        uint32 callbackGasLimit;    // callback gas limit for entropy callback
        address feeRecipient;
        uint256 protocolFeePercent; // 0..20
        address creator;
        string name;
        uint256 ticketPrice;
        uint256 winningPot;
        uint64 minTickets;
        uint64 maxTickets;          // 0 = no max (still capped by HARD_CAP_TICKETS)
        uint64 durationSeconds;
        uint32 minPurchaseAmount;   // 0 = no minimum
    }

    struct TicketRange {
        address buyer;
        uint96 upperBound; // inclusive upper bound of sold tickets count (monotonic increasing)
    }

    // ---------- Errors ----------
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
    error InvalidCallbackGasLimit();

    error NotFundingPending();
    error FundingMismatch();
    error AlreadyFunded();

    error LotteryNotOpen();
    error LotteryExpired();
    error TicketLimitReached();
    error CreatorCannotBuy();
    error InvalidCount();
    error BatchTooLarge();
    error BatchTooSmall();
    error TooManyRanges();
    error Overflow();
    error UnexpectedTransferAmount();

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
    error NativeRefundFailed();
    error ZeroAddress();
    error AccountingMismatch();

    // ---------- Events ----------
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

    event RefundAllocated(address indexed user, uint256 amount); // emitted for ticket refunds and pot refunds
    event FundsClaimed(address indexed user, uint256 amount);
    event NativeRefundAllocated(address indexed user, uint256 amount);
    event NativeClaimed(address indexed to, uint256 amount);

    event PrizeAllocated(address indexed user, uint256 amount, uint8 indexed reason);
    event FundingConfirmed(address indexed caller, uint256 expectedPot);

    // ---------- Immutable config ----------
    IERC20 public immutable usdcToken;
    IEntropyV2 public immutable entropy;
    address public immutable entropyProvider;
    uint32 public immutable callbackGasLimit;

    address public immutable creator;
    address public immutable feeRecipient;
    uint256 public immutable protocolFeePercent;

    // ---------- Constants ----------
    uint256 public constant MAX_BATCH_BUY = 1000;
    uint256 public constant MAX_RANGES = 20_000;
    uint256 public constant MIN_NEW_RANGE_COST = 1_000_000; // 1 USDC (6 decimals)
    uint256 public constant MAX_TICKET_PRICE = 100_000 * 1e6;
    uint256 public constant MAX_POT_SIZE = 10_000_000 * 1e6;
    uint64 public constant MAX_DURATION = 365 days;
    uint256 public constant PRIVILEGED_HATCH_DELAY = 1 days; // used only for creator (non-governance) cancel path
    uint256 public constant PUBLIC_HATCH_DELAY = 7 days;
    uint256 public constant HARD_CAP_TICKETS = 10_000_000;

    // ---------- State ----------
    enum Status { FundingPending, Open, Drawing, Completed, Canceled }
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

    // accounting
    uint256 public totalReservedUSDC;      // amount the contract owes users in USDC (claimable)
    uint256 public totalClaimableNative;   // total outstanding native-coin refunds/claims

    // drawing / winner
    address public winner;
    address public selectedProvider;
    uint64 public drawingRequestedAt;
    uint64 public entropyRequestId;
    uint256 public soldAtDrawing;

    // cancel snapshot
    uint256 public soldAtCancel;
    uint64 public canceledAt;

    // tickets
    TicketRange[] public ticketRanges;
    mapping(address => uint256) public ticketsOwned;

    // claims
    mapping(address => uint256) public claimableFunds;  // USDC claims (winner/creator/fees + pot refund)
    mapping(address => uint256) public claimableNative; // native refunds when a call refund fails

    bool public creatorPotRefunded;

    constructor(LotteryParams memory params) {
        if (params.entropy == address(0)) revert InvalidEntropy();
        if (params.usdcToken == address(0)) revert InvalidUSDC();
        if (params.entropyProvider == address(0)) revert InvalidProvider();
        if (params.feeRecipient == address(0)) revert InvalidFeeRecipient();
        if (params.creator == address(0)) revert InvalidCreator();
        if (params.protocolFeePercent > 20) revert FeeTooHigh();
        if (params.callbackGasLimit == 0) revert InvalidCallbackGasLimit();

        // Enforce "USDC-like" 6 decimals
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

        // Ensure any new range purchase meets minimum cost threshold
        uint256 minEntry = (params.minPurchaseAmount == 0) ? 1 : uint256(params.minPurchaseAmount);
        uint256 requiredMinPrice = (MIN_NEW_RANGE_COST + minEntry - 1) / minEntry;
        if (params.ticketPrice < requiredMinPrice) revert BatchTooCheap();

        usdcToken = IERC20(params.usdcToken);
        entropy = IEntropyV2(params.entropy);
        entropyProvider = params.entropyProvider;
        callbackGasLimit = params.callbackGasLimit;

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

    /**
     * @notice Confirms the lottery is funded with at least winningPot USDC and opens it.
     * @dev No privileged role: anyone can call once the USDC is present.
     */
    function confirmFunding() external {
        if (status != Status.FundingPending) revert NotFundingPending();

        uint256 bal = usdcToken.balanceOf(address(this));
        if (bal < winningPot) revert FundingMismatch();

        // prevent double-confirm
        if (totalReservedUSDC != 0) revert AlreadyFunded();

        totalReservedUSDC = winningPot;
        status = Status.Open;

        emit FundingConfirmed(msg.sender, winningPot);
    }

    function buyTickets(uint256 count) external nonReentrant {
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

        uint256 rangeIndex;
        bool isNewRange;

        // Effects: update ranges first
        if (returning) {
            rangeIndex = ticketRanges.length - 1;
            isNewRange = false;
            ticketRanges[rangeIndex].upperBound = uint96(newTotal);
        } else {
            ticketRanges.push(TicketRange({buyer: msg.sender, upperBound: uint96(newTotal)}));
            rangeIndex = ticketRanges.length - 1;
            isNewRange = true;
        }

        // Effects: accounting
        totalReservedUSDC += totalCost;
        ticketRevenue += totalCost;
        ticketsOwned[msg.sender] += count;

        emit TicketsPurchased(msg.sender, count, totalCost, newTotal, rangeIndex, isNewRange);

        // Interaction: pull USDC and verify exact amount received
        uint256 balBefore = usdcToken.balanceOf(address(this));
        usdcToken.safeTransferFrom(msg.sender, address(this), totalCost);
        uint256 balAfter = usdcToken.balanceOf(address(this));
        if (balAfter < balBefore + totalCost) revert UnexpectedTransferAmount();
    }

    function finalize() external payable nonReentrant {
        if (status != Status.Open) revert LotteryNotOpen();
        if (entropyRequestId != 0) revert RequestPending();

        uint256 sold = getSold();
        bool isFull = (maxTickets > 0 && sold >= maxTickets);
        bool isExpired = (block.timestamp >= deadline);

        if (!isFull && !isExpired) revert NotReadyToFinalize();

        // Expired with insufficient participation => cancel
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

        uint256 fee = entropy.getFeeV2(callbackGasLimit);
        if (msg.value < fee) revert InsufficientFee();

        // userRand is a salt; security comes from Entropy provider randomness.
        bytes32 userRand = keccak256(
            abi.encodePacked(address(this), sold, ticketRevenue, blockhash(block.number - 1))
        );

        uint64 requestId = entropy.requestV2{value: fee}(entropyProvider, userRand, callbackGasLimit);
        if (requestId == 0) revert InvalidRequest();

        entropyRequestId = requestId;

        if (msg.value > fee) _safeNativeTransfer(msg.sender, msg.value - fee);

        emit LotteryFinalized(requestId, sold, entropyProvider);
    }

    /**
     * @dev Entropy calls this function name/signature on the consumer.
     */
    function _entropyCallback(uint64 sequenceNumber, address provider, bytes32 randomNumber) external {
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

        uint256 len = ticketRanges.length;
        // Ensure last upperBound matches soldAtDrawing snapshot
        if (len == 0 || uint256(ticketRanges[len - 1].upperBound) != total) revert AccountingMismatch();

        // Clear drawing state
        entropyRequestId = 0;
        soldAtDrawing = 0;
        drawingRequestedAt = 0;
        selectedProvider = address(0);

        uint256 winningIndex = uint256(rand) % total;
        address w = _findWinner(winningIndex);

        winner = w;
        status = Status.Completed;

        // Fees
        uint256 feePot = (winningPot * protocolFeePercent) / 100;
        uint256 feeRev = (ticketRevenue * protocolFeePercent) / 100;

        uint256 winnerAmount = winningPot - feePot;
        uint256 creatorNet = ticketRevenue - feeRev;
        uint256 protocolAmount = feePot + feeRev;

        // Allocate pull-based claims
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
    }

    function _findWinner(uint256 winningTicket) internal view returns (address) {
        uint256 low = 0;
        uint256 high = ticketRanges.length - 1;
        while (low < high) {
            uint256 mid = low + (high - low) / 2;
            if (ticketRanges[mid].upperBound > winningTicket) high = mid;
            else low = mid + 1;
        }
        return ticketRanges[low].buyer;
    }

    /**
     * @notice Emergency hatch: cancel if randomness is stuck.
     * @dev Creator can cancel after 1 day; anyone after 7 days.
     */
    function forceCancelStuck() external nonReentrant {
        if (status != Status.Drawing) revert NotDrawing();

        bool privileged = (msg.sender == creator);
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

        uint256 soldSnapshot = getSold();
        soldAtCancel = soldSnapshot;
        canceledAt = uint64(block.timestamp);

        status = Status.Canceled;

        // clear drawing state (if any)
        selectedProvider = address(0);
        drawingRequestedAt = 0;
        entropyRequestId = 0;
        soldAtDrawing = 0;

        uint256 potRefund = 0;
        if (!creatorPotRefunded && winningPot > 0) {
            creatorPotRefunded = true;
            potRefund = winningPot;

            // creator can pull pot back
            claimableFunds[creator] += winningPot;
            emit PrizeAllocated(creator, winningPot, 5);
            emit RefundAllocated(creator, winningPot);
        }

        emit LotteryCanceled(reason, soldSnapshot, ticketRevenue, potRefund);
    }

    /**
     * @notice Single-step withdraw for ALL USDC claims:
     * - winner/creator/feeRecipient claims (Completed)
     * - creator pot refund (Canceled)
     * - ticket refunds (Canceled) are computed lazily here so users only call withdrawFunds().
     */
    function withdrawFunds() external nonReentrant {
        uint256 amount = claimableFunds[msg.sender];

        // If canceled, include ticket refund automatically (no separate "claim refund" step).
        if (status == Status.Canceled) {
            uint256 tix = ticketsOwned[msg.sender];
            if (tix > 0) {
                // Effects first to prevent double-refund
                ticketsOwned[msg.sender] = 0;

                uint256 refund = tix * ticketPrice;
                amount += refund;

                emit PrizeAllocated(msg.sender, refund, 3);
                emit RefundAllocated(msg.sender, refund);
            }
        }

        if (amount == 0) revert NothingToClaim();

        // Effects
        claimableFunds[msg.sender] = 0;

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

    function withdrawNativeTo(address to) public nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = claimableNative[msg.sender];
        if (amount == 0) revert NothingToClaim();
        if (totalClaimableNative < amount) revert AccountingMismatch();

        claimableNative[msg.sender] = 0;
        totalClaimableNative -= amount;

        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert NativeRefundFailed();

        emit NativeClaimed(to, amount);
    }

    function getSold() public view returns (uint256) {
        uint256 len = ticketRanges.length;
        return len == 0 ? 0 : uint256(ticketRanges[len - 1].upperBound);
    }

    // Needed to receive ETH for entropy fee refunds and any direct native transfers.
    receive() external payable {}
}