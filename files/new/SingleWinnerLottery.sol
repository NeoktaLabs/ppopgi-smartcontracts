// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@pythnetwork/entropy-sdk-solidity/IEntropyV2.sol";

contract SingleWinnerLottery is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct LotteryParams {
        address usdcToken;
        address entropy;
        address entropyProvider;
        uint32 callbackGasLimit;
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

    struct TicketRange {
        address buyer;
        uint96 upperBound;
    }

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

    // New range throttle
    error NewRangeMinNotMet(uint256 required, uint256 provided);

    error RequestPending();
    error NotReadyToFinalize();
    error NoParticipants();
    error InsufficientFee(); // kept for finalize() legacy behavior
    error InvalidRequest();

    // Better UX errors for finalize wrappers
    error InvalidFeeAmount(uint256 required, uint256 provided);
    error FeeExceedsMax(uint256 fee, uint256 maxFee);

    error UnauthorizedCallback();
    error NotDrawing();
    error CannotCancel();
    error EarlyCancellationRequest();
    error EmergencyHatchLocked();

    error NothingToClaim();
    error NativeRefundFailed();
    error ZeroAddress();
    error AccountingMismatch();

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
    event NativeClaimed(address indexed to, uint256 amount);

    event PrizeAllocated(address indexed user, uint256 amount, uint8 indexed reason);
    event FundingConfirmed(address indexed caller, uint256 expectedPot);

    IERC20 public immutable usdcToken;
    IEntropyV2 public immutable entropy;
    address public immutable entropyProvider;
    uint32 public immutable callbackGasLimit;

    address public immutable creator;
    address public immutable feeRecipient;
    uint256 public immutable protocolFeePercent;

    uint256 public constant MAX_BATCH_BUY = 1000;
    uint256 public constant MAX_RANGES = 100_000; // increased for big raffles
    uint256 public constant MAX_TICKET_PRICE = 100_000 * 1e6;
    uint256 public constant MAX_POT_SIZE = 10_000_000 * 1e6;
    uint64 public constant MAX_DURATION = 365 days;
    uint256 public constant PRIVILEGED_HATCH_DELAY = 1 days;
    uint256 public constant PUBLIC_HATCH_DELAY = 7 days;
    uint256 public constant HARD_CAP_TICKETS = 10_000_000;

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

    uint256 public totalReservedUSDC;
    uint256 public totalClaimableNative;

    address public winner;
    address public selectedProvider;
    uint64 public drawingRequestedAt;
    uint64 public entropyRequestId;
    uint256 public soldAtDrawing;

    uint256 public soldAtCancel;
    uint64 public canceledAt;

    TicketRange[] public ticketRanges;
    mapping(address => uint256) public ticketsOwned;

    mapping(address => uint256) public claimableFunds;
    mapping(address => uint256) public claimableNative;

    bool public creatorPotRefunded;

    constructor(LotteryParams memory params) {
        if (params.entropy == address(0)) revert InvalidEntropy();
        if (params.usdcToken == address(0)) revert InvalidUSDC();
        if (params.entropyProvider == address(0)) revert InvalidProvider();
        if (params.feeRecipient == address(0)) revert InvalidFeeRecipient();
        if (params.creator == address(0)) revert InvalidCreator();
        if (params.protocolFeePercent > 20) revert FeeTooHigh();
        if (params.callbackGasLimit == 0) revert InvalidCallbackGasLimit();

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

    function confirmFunding() external {
        if (status != Status.FundingPending) revert NotFundingPending();

        uint256 bal = usdcToken.balanceOf(address(this));
        if (bal < winningPot) revert FundingMismatch();

        if (totalReservedUSDC != 0) revert AlreadyFunded();

        totalReservedUSDC = winningPot;
        status = Status.Open;

        emit FundingConfirmed(msg.sender, winningPot);
    }

    // =========================
    // UX / helper views (existing)
    // =========================

    function isOpen() external view returns (bool) {
        return status == Status.Open && block.timestamp < deadline;
    }

    function isExpired() public view returns (bool) {
        return block.timestamp >= deadline;
    }

    function isSoldOut() public view returns (bool) {
        return (maxTickets > 0 && getSold() >= maxTickets);
    }

    function isFinalizable() external view returns (bool) {
        if (status != Status.Open) return false;
        return isExpired() || isSoldOut();
    }

    function isCancelable() external view returns (bool) {
        if (status != Status.Open) return false;
        if (block.timestamp < deadline) return false;
        return getSold() < minTickets;
    }

    function isEmergencyCancelable()
        external
        view
        returns (bool privilegedNow, bool publicNow, uint256 privilegedAt, uint256 publicAt)
    {
        if (status != Status.Drawing) {
            return (false, false, 0, 0);
        }
        privilegedAt = uint256(drawingRequestedAt) + PRIVILEGED_HATCH_DELAY;
        publicAt = uint256(drawingRequestedAt) + PUBLIC_HATCH_DELAY;

        privilegedNow = block.timestamp > privilegedAt;
        publicNow = block.timestamp > publicAt;
    }

    function quoteBuy(uint256 count) external view returns (uint256 totalCost) {
        return ticketPrice * count;
    }

    function remainingTickets() external view returns (uint256 remaining, bool unlimited) {
        if (maxTickets == 0) return (0, true);
        uint256 sold = getSold();
        if (sold >= maxTickets) return (0, false);
        return (uint256(maxTickets) - sold, false);
    }

    function maxBuyableNow() external view returns (uint256 maxNow) {
        if (status != Status.Open) return 0;
        if (block.timestamp >= deadline) return 0;

        uint256 sold = getSold();
        uint256 cap = HARD_CAP_TICKETS;

        if (maxTickets > 0 && uint256(maxTickets) < cap) cap = uint256(maxTickets);
        if (sold >= cap) return 0;

        uint256 remain = cap - sold;
        maxNow = remain > MAX_BATCH_BUY ? MAX_BATCH_BUY : remain;
    }

    function timeLeft() external view returns (uint256) {
        if (block.timestamp >= deadline) return 0;
        return uint256(deadline) - block.timestamp;
    }

    function getFinalizeFee() public view returns (uint256) {
        return entropy.getFeeV2(callbackGasLimit);
    }

    function finalizeExact() external payable nonReentrant {
        uint256 fee = getFinalizeFee();
        if (msg.value != fee) revert InvalidFeeAmount(fee, msg.value);
        _finalizeInternal(fee, msg.value);
    }

    function finalizeWithMaxFee(uint256 maxFee) external payable nonReentrant {
        uint256 fee = getFinalizeFee();
        if (fee > maxFee) revert FeeExceedsMax(fee, maxFee);
        if (msg.value < fee) revert InvalidFeeAmount(fee, msg.value);
        _finalizeInternal(fee, msg.value);
    }

    function getTicketRanges(uint256 start, uint256 limit)
        external
        view
        returns (address[] memory buyers, uint96[] memory upperBounds)
    {
        uint256 n = ticketRanges.length;

        // ✅ FIX: must return empty dynamic arrays
        if (start >= n || limit == 0) return (new address[](0), new uint96[](0));

        uint256 end = start + limit;
        if (end > n) end = n;

        buyers = new address[](end - start);
        upperBounds = new uint96[](end - start);

        for (uint256 i = start; i < end; i++) {
            TicketRange storage r = ticketRanges[i];
            buyers[i - start] = r.buyer;
            upperBounds[i - start] = r.upperBound;
        }
    }

    function getTicketRangesCount() external view returns (uint256) {
        return ticketRanges.length;
    }

    function getAccounting()
        external
        view
        returns (
            uint256 reservedUSDC,
            uint256 usdcBalance,
            uint256 excessUSDC,
            uint256 claimableNativeTotal,
            uint256 nativeBalance
        )
    {
        reservedUSDC = totalReservedUSDC;
        usdcBalance = usdcToken.balanceOf(address(this));
        excessUSDC = usdcBalance > reservedUSDC ? (usdcBalance - reservedUSDC) : 0;
        claimableNativeTotal = totalClaimableNative;
        nativeBalance = address(this).balance;
    }

    function findWinner(uint256 ticketIndex) external view returns (address) {
        uint256 sold = getSold();
        if (sold == 0 || ticketIndex >= sold) revert InvalidCount();
        return _findWinner(ticketIndex);
    }

    function currentNewRangeMin() external view returns (uint256 required) {
        required = _minTicketsForNewRange();
        if (minPurchaseAmount > required) required = minPurchaseAmount;
    }

    // =========================
    // Added UX/indexer helpers
    // =========================

    /// @notice Packed snapshot for UIs (reduces RPC calls).
    function getState()
        external
        view
        returns (
            Status st,
            uint64 created,
            uint64 dl,
            uint256 sold,
            uint256 price,
            uint256 pot,
            uint256 revenue,
            uint64 minTix,
            uint64 maxTix,
            uint32 minBuy,
            address win,
            uint64 requestId,
            address provider,
            uint64 drawingAt
        )
    {
        st = status;
        created = createdAt;
        dl = deadline;
        sold = getSold();
        price = ticketPrice;
        pot = winningPot;
        revenue = ticketRevenue;
        minTix = minTickets;
        maxTix = maxTickets;
        minBuy = minPurchaseAmount;
        win = winner;
        requestId = entropyRequestId;
        provider = selectedProvider;
        drawingAt = drawingRequestedAt;
    }

    /// @notice User-centric snapshot for dashboards/wallet UIs.
    function getUserStatus(address user)
        external
        view
        returns (
            uint256 tickets,
            uint256 claimableUsdc,
            uint256 claimableEth,
            bool isLastBuyer,
            bool canBuy,
            uint256 minBuyNow
        )
    {
        tickets = ticketsOwned[user];
        claimableUsdc = claimableFunds[user];
        claimableEth = claimableNative[user];

        uint256 len = ticketRanges.length;
        isLastBuyer = (len > 0 && ticketRanges[len - 1].buyer == user);

        canBuy = (status == Status.Open && block.timestamp < deadline && user != creator && !isSoldOut());

        // Mirrors minTicketsToBuy logic
        minBuyNow = (minPurchaseAmount == 0) ? 1 : uint256(minPurchaseAmount);
        if (!isLastBuyer) {
            uint256 newMin = _minTicketsForNewRange();
            if (newMin > minBuyNow) minBuyNow = newMin;
        }
    }

    /// @notice Combined action flags + fee + time left, tailored for the caller.
    /// @dev Adds `finalizeWouldCancel` so UIs don't promise a winner draw when it would cancel/refund.
    function getActionFlags(address caller)
        external
        view
        returns (
            bool canFinalize,
            bool finalizeWouldCancel,
            bool canCancel,
            bool canEmergencyCancel,
            uint256 finalizeFee,
            uint256 timeLeftSec
        )
    {
        finalizeFee = getFinalizeFee();
        timeLeftSec = (block.timestamp >= deadline) ? 0 : (uint256(deadline) - block.timestamp);

        bool open = (status == Status.Open);
        bool drawing = (status == Status.Drawing);

        bool expiredNow = isExpired();
        bool soldOutNow = isSoldOut();
        uint256 sold = getSold();

        canFinalize = open && (expiredNow || soldOutNow);
        finalizeWouldCancel = open && expiredNow && (sold < minTickets);

        canCancel = open && (block.timestamp >= deadline) && (sold < minTickets);

        if (!drawing) {
            canEmergencyCancel = false;
        } else {
            bool privileged = (caller == creator);
            if (privileged) {
                canEmergencyCancel = block.timestamp > (uint256(drawingRequestedAt) + PRIVILEGED_HATCH_DELAY);
            } else {
                canEmergencyCancel = block.timestamp > (uint256(drawingRequestedAt) + PUBLIC_HATCH_DELAY);
            }
        }
    }

    /// @notice Economic preview based on current ticketRevenue (useful for UI transparency).
    function previewPayouts()
        external
        view
        returns (
            uint256 feePot,
            uint256 feeRevenue,
            uint256 winnerAmountIfDrawnNow,
            uint256 creatorAmountIfDrawnNow,
            uint256 protocolAmountIfDrawnNow
        )
    {
        feePot = (winningPot * protocolFeePercent) / 100;
        feeRevenue = (ticketRevenue * protocolFeePercent) / 100;

        winnerAmountIfDrawnNow = winningPot - feePot;
        creatorAmountIfDrawnNow = ticketRevenue - feeRevenue;
        protocolAmountIfDrawnNow = feePot + feeRevenue;
    }

    /// @notice Batch claimables/tickets for many users (indexer/admin UI helper).
    function getClaimables(address[] calldata users)
        external
        view
        returns (uint256[] memory usdcAmounts, uint256[] memory nativeAmounts, uint256[] memory tickets)
    {
        uint256 n = users.length;
        usdcAmounts = new uint256[](n);
        nativeAmounts = new uint256[](n);
        tickets = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            address u = users[i];
            usdcAmounts[i] = claimableFunds[u];
            nativeAmounts[i] = claimableNative[u];
            tickets[i] = ticketsOwned[u];
        }
    }

    // =========================
    // Range throttling helpers
    // =========================

    function _minTicketsForNewRange() internal view returns (uint256) {
        uint256 r = ticketRanges.length;
        if (r < 10_000) return 1;
        if (r < 25_000) return 2;
        if (r < 50_000) return 5;
        if (r < 75_000) return 10;
        return 20;
    }

    function minTicketsToBuy(address user) external view returns (uint256 required) {
        required = (minPurchaseAmount == 0) ? 1 : uint256(minPurchaseAmount);

        uint256 len = ticketRanges.length;
        bool returning = (len > 0 && ticketRanges[len - 1].buyer == user);

        if (!returning) {
            uint256 newMin = _minTicketsForNewRange();
            if (newMin > required) required = newMin;
        }
    }

    // =========================
    // Core functions (unchanged)
    // =========================

    function buyTickets(uint256 count) external nonReentrant {
        if (status != Status.Open) revert LotteryNotOpen();
        if (count == 0) revert InvalidCount();
        if (count > MAX_BATCH_BUY) revert BatchTooLarge();
        if (block.timestamp >= deadline) revert LotteryExpired();
        if (msg.sender == creator) revert CreatorCannotBuy();

        // Keep creator-configured minimum for everyone
        if (minPurchaseAmount > 0 && count < minPurchaseAmount) revert BatchTooSmall();

        uint256 currentSold = getSold();
        uint256 newTotal = currentSold + count;

        if (newTotal > type(uint96).max) revert Overflow();
        if (newTotal > HARD_CAP_TICKETS) revert TicketLimitReached();
        if (maxTickets > 0 && newTotal > maxTickets) revert TicketLimitReached();

        bool returning = (ticketRanges.length > 0 && ticketRanges[ticketRanges.length - 1].buyer == msg.sender);

        // Throttle only when this buy would create a NEW range
        if (!returning) {
            if (ticketRanges.length >= MAX_RANGES) revert TooManyRanges();

            uint256 required = _minTicketsForNewRange();
            if (minPurchaseAmount > required) required = minPurchaseAmount;

            if (count < required) revert NewRangeMinNotMet(required, count);
        }

        uint256 totalCost = ticketPrice * count;

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

        uint256 balBefore = usdcToken.balanceOf(address(this));
        usdcToken.safeTransferFrom(msg.sender, address(this), totalCost);
        uint256 balAfter = usdcToken.balanceOf(address(this));
        if (balAfter < balBefore + totalCost) revert UnexpectedTransferAmount();
    }

    function finalize() external payable nonReentrant {
        // preserve original behavior
        if (status != Status.Open) revert LotteryNotOpen();
        if (entropyRequestId != 0) revert RequestPending();

        uint256 sold = getSold();
        bool isFull = (maxTickets > 0 && sold >= maxTickets);
        bool isExpiredNow = (block.timestamp >= deadline);

        if (!isFull && !isExpiredNow) revert NotReadyToFinalize();

        if (isExpiredNow && sold < minTickets) {
            _cancelAndRefundCreator("Min tickets not reached");
            if (msg.value > 0) _safeNativeTransfer(msg.sender, msg.value);
            return;
        }

        if (sold == 0) revert NoParticipants();

        uint256 fee = getFinalizeFee();
        if (msg.value < fee) revert InsufficientFee();

        _finalizeInternal(fee, msg.value);
    }

    function _finalizeInternal(uint256 fee, uint256 paid) internal {
        if (status != Status.Open) revert LotteryNotOpen();
        if (entropyRequestId != 0) revert RequestPending();

        uint256 sold = getSold();
        bool isFull = (maxTickets > 0 && sold >= maxTickets);
        bool isExpiredNow = (block.timestamp >= deadline);

        if (!isFull && !isExpiredNow) revert NotReadyToFinalize();

        if (isExpiredNow && sold < minTickets) {
            _cancelAndRefundCreator("Min tickets not reached");
            if (paid > 0) _safeNativeTransfer(msg.sender, paid);
            return;
        }

        if (sold == 0) revert NoParticipants();

        status = Status.Drawing;
        soldAtDrawing = sold;
        drawingRequestedAt = uint64(block.timestamp);
        selectedProvider = entropyProvider;

        bytes32 userRand =
            keccak256(abi.encodePacked(address(this), sold, ticketRevenue, blockhash(block.number - 1)));

        uint64 requestId = entropy.requestV2{value: fee}(entropyProvider, userRand, callbackGasLimit);
        if (requestId == 0) revert InvalidRequest();

        entropyRequestId = requestId;

        if (paid > fee) _safeNativeTransfer(msg.sender, paid - fee);

        emit LotteryFinalized(requestId, sold, entropyProvider);
    }

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
        if (len == 0 || uint256(ticketRanges[len - 1].upperBound) != total) revert AccountingMismatch();

        entropyRequestId = 0;
        soldAtDrawing = 0;
        drawingRequestedAt = 0;
        selectedProvider = address(0);

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

        selectedProvider = address(0);
        drawingRequestedAt = 0;
        entropyRequestId = 0;
        soldAtDrawing = 0;

        uint256 potRefund = 0;
        if (!creatorPotRefunded && winningPot > 0) {
            creatorPotRefunded = true;
            potRefund = winningPot;

            claimableFunds[creator] += winningPot;
            emit PrizeAllocated(creator, winningPot, 5);
            emit RefundAllocated(creator, winningPot);
        }

        emit LotteryCanceled(reason, soldSnapshot, ticketRevenue, potRefund);
    }

    function withdrawFunds() external nonReentrant {
        uint256 amount = claimableFunds[msg.sender];

        // Ticket refunds are implicit on cancel: just call withdrawFunds()
        if (status == Status.Canceled) {
            uint256 tix = ticketsOwned[msg.sender];
            if (tix > 0) {
                ticketsOwned[msg.sender] = 0;

                uint256 refund = tix * ticketPrice;
                amount += refund;

                emit PrizeAllocated(msg.sender, refund, 3);
                emit RefundAllocated(msg.sender, refund);
            }
        }

        if (amount == 0) revert NothingToClaim();

        claimableFunds[msg.sender] = 0;

        if (totalReservedUSDC < amount) revert AccountingMismatch();
        totalReservedUSDC -= amount;

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

    receive() external payable {}
}