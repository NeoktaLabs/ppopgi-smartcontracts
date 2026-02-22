// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

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

    error NewRangeMinNotMet(uint256 required, uint256 provided);

    error RequestPending();
    error NotReadyToFinalize();
    error NoParticipants();
    error InvalidRequest();

    error InvalidFeeAmount(uint256 required, uint256 provided);

    error UnauthorizedCallback();
    error NotDrawing();
    error CannotCancel();
    error EarlyCancellationRequest();
    error EmergencyHatchLocked();

    error NothingToClaim();
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
    uint256 public constant MAX_RANGES = 100_000;
    uint256 public constant MAX_TICKET_PRICE = 100_000 * 1e6;
    uint256 public constant MAX_POT_SIZE = 10_000_000 * 1e6;
    uint64 public constant MAX_DURATION = 365 days;
    uint256 public constant PRIVILEGED_HATCH_DELAY = 1 days;
    uint256 public constant PUBLIC_HATCH_DELAY = 7 days;
    uint256 public constant HARD_CAP_TICKETS = 10_000_000;

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

    uint256 public totalReservedUSDC;

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

    bool public creatorPotRefunded;

    uint64 public finalizeNonce;

    constructor(LotteryParams memory params) {
        if (params.entropy == address(0)) revert InvalidEntropy();
        if (params.usdcToken == address(0)) revert InvalidUSDC();
        if (params.entropyProvider == address(0)) revert InvalidProvider();
        if (params.feeRecipient == address(0)) revert InvalidFeeRecipient();
        if (params.creator == address(0)) revert InvalidCreator();
        if (params.protocolFeePercent > 20) revert FeeTooHigh();
        if (params.callbackGasLimit == 0) revert InvalidCallbackGasLimit();
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
        _finalizeInternal(fee);
    }

    function getTicketRanges(uint256 start, uint256 limit)
        external
        view
        returns (address[] memory buyers, uint96[] memory upperBounds)
    {
        uint256 n = ticketRanges.length;
        if (start >= n || limit == 0) return (new address, new uint96);

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
            uint256 excessUSDC
        )
    {
        reservedUSDC = totalReservedUSDC;
        usdcBalance = usdcToken.balanceOf(address(this));
        excessUSDC = usdcBalance > reservedUSDC ? (usdcBalance - reservedUSDC) : 0;
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

    function quoteBuyFor(address user, uint256 count)
        external
        view
        returns (
            uint256 totalCost,
            bool canBuy,
            uint256 minRequired,
            uint256 maxNow
        )
    {
        totalCost = ticketPrice * count;

        minRequired = (minPurchaseAmount == 0) ? 1 : uint256(minPurchaseAmount);
        uint256 len = ticketRanges.length;
        bool isLastBuyer = (len > 0 && ticketRanges[len - 1].buyer == user);
        if (!isLastBuyer) {
            uint256 newMin = _minTicketsForNewRange();
            if (newMin > minRequired) minRequired = newMin;
        }

        if (status != Status.Open || block.timestamp >= deadline) {
            maxNow = 0;
        } else {
            uint256 sold = getSold();
            uint256 cap = HARD_CAP_TICKETS;
            if (maxTickets > 0 && uint256(maxTickets) < cap) cap = uint256(maxTickets);
            if (sold >= cap) maxNow = 0;
            else {
                uint256 remain = cap - sold;
                maxNow = remain > MAX_BATCH_BUY ? MAX_BATCH_BUY : remain;
            }
        }

        canBuy =
            (status == Status.Open) &&
            (block.timestamp < deadline) &&
            (user != creator) &&
            (!isSoldOut()) &&
            (count > 0) &&
            (count <= MAX_BATCH_BUY) &&
            (count >= minRequired) &&
            (count <= maxNow);
    }

    function getTicketStats()
        external
        view
        returns (
            uint256 sold,
            uint256 rangeCount,
            uint256 remaining,
            bool unlimited
        )
    {
        sold = getSold();
        rangeCount = ticketRanges.length;

        if (maxTickets == 0) {
            unlimited = true;
            remaining = 0;
        } else {
            unlimited = false;
            remaining = sold >= maxTickets ? 0 : (uint256(maxTickets) - sold);
        }
    }

    function getOutcome()
        external
        view
        returns (
            Status st,
            address winnerAddr,
            uint64 requestId,
            address provider,
            uint64 drawingAt,
            uint256 soldSnapshotAtDrawing,
            uint256 soldSnapshotAtCancel,
            uint64 canceledAtTs
        )
    {
        st = status;
        winnerAddr = winner;
        requestId = entropyRequestId;
        provider = selectedProvider;
        drawingAt = drawingRequestedAt;
        soldSnapshotAtDrawing = soldAtDrawing;
        soldSnapshotAtCancel = soldAtCancel;
        canceledAtTs = canceledAt;
    }

    function getTicketsOwnedBatch(address[] calldata users) external view returns (uint256[] memory out) {
        uint256 n = users.length;
        out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) out[i] = ticketsOwned[users[i]];
    }

    function getClaimablesBatch(address[] calldata users)
        external
        view
        returns (uint256[] memory usdcAmounts)
    {
        uint256 n = users.length;
        usdcAmounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            usdcAmounts[i] = claimableFunds[users[i]];
        }
    }

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

        bool returning = (ticketRanges.length > 0 && ticketRanges[ticketRanges.length - 1].buyer == msg.sender);

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

    function _finalizeInternal(uint256 fee) internal {
        if (status != Status.Open) revert LotteryNotOpen();
        if (entropyRequestId != 0) revert RequestPending();

        uint256 sold = getSold();
        bool isFull = (maxTickets > 0 && sold >= maxTickets);
        bool isExpiredNow = (block.timestamp >= deadline);

        if (!isFull && !isExpiredNow) revert NotReadyToFinalize();

        if (isExpiredNow && sold < minTickets) {
            _cancelAndRefundCreator("Min tickets not reached");
            return;
        }

        if (sold == 0) revert NoParticipants();

        status = Status.Drawing;
        soldAtDrawing = sold;
        drawingRequestedAt = uint64(block.timestamp);
        selectedProvider = entropyProvider;

        finalizeNonce += 1;

        // ✅ PATCH: remove msg.sender from userRand to avoid caller-controlled seed input
        bytes32 userRand = keccak256(
            abi.encodePacked(
                address(this),
                sold,
                ticketRevenue,
                createdAt,
                deadline,
                finalizeNonce
            )
        );

        uint64 requestId = entropy.requestV2{value: fee}(entropyProvider, userRand, callbackGasLimit);
        if (requestId == 0) revert InvalidRequest();

        entropyRequestId = requestId;

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

    function getSold() public view returns (uint256) {
        uint256 len = ticketRanges.length;
        return len == 0 ? 0 : uint256(ticketRanges[len - 1].upperBound);
    }

    receive() external payable {}
}