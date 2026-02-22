// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@pythnetwork/entropy-sdk-solidity/IEntropyV2.sol";

contract SingleWinnerRaffle is ReentrancyGuard {
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
        address finalizer;
        address guardian;
    }

    error ZeroAddress();
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

    error NotFactory();
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
    error WrongEntropyFee();
    error InvalidRequest();

    error UnauthorizedCallback();
    error UnauthorizedFinalizer();
    error UnauthorizedGuardian();

    error NotDrawing();
    error NotCanceled();
    error EarlyCancellationRequest();

    error NothingToClaim();
    error NothingToRefund();
    error AccountingMismatch();
    error UnexpectedTransferAmount();

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
    event ProtocolFeesCollected(uint256 amount);
    event PrizeAllocated(address indexed user, uint256 amount, uint8 indexed reason);
    event FundingConfirmed(address indexed funder, uint256 amount);
    event TicketRefundClaimed(address indexed user, uint256 amount);

    IERC20 public immutable usdcToken;
    address public immutable creator;
    address public immutable feeRecipient;
    uint256 public immutable protocolFeePercent;

    IEntropyV2 public immutable entropy;
    address public immutable entropyProvider;
    uint32 public immutable callbackGasLimit;

    address public immutable factory;
    address public immutable finalizer;
    address public immutable guardian;

    uint256 public constant MAX_BATCH_BUY = 1000;

    uint256 public constant MAX_RANGES = 100_000;

    uint256 public constant MIN_NEW_RANGE_COST_BASE = 1_000_000; // 1 USDC

    uint256 public constant RANGE_STEP = 10_000;
    uint256 public constant RANGE_COST_STEP = 1_000_000; // 1 USDC

    uint256 public constant MAX_TICKET_PRICE = 100_000 * 1e6;
    uint256 public constant MAX_POT_SIZE = 10_000_000 * 1e6;
    uint64 public constant MAX_DURATION = 365 days;
    uint256 public constant HATCH_DELAY = 2 hours;
    uint256 public constant HARD_CAP_TICKETS = 10_000_000;

    uint256 public totalReservedUSDC;

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

    address public winner;
    address public selectedProvider;
    uint64 public drawingRequestedAt;
    uint64 public entropyRequestId;
    uint256 public soldAtDrawing;

    uint256 public soldAtCancel;
    uint64 public canceledAt;

    struct TicketRange { address buyer; uint96 upperBound; }
    TicketRange[] public ticketRanges;

    mapping(address => uint256) public ticketsOwned;
    mapping(address => uint256) public claimableFunds;

    bool public creatorPotRefunded;

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier onlyFinalizer() {
        if (msg.sender != finalizer) revert UnauthorizedFinalizer();
        _;
    }

    modifier onlyGuardianOrFinalizer() {
        if (msg.sender != guardian && msg.sender != finalizer) revert UnauthorizedGuardian();
        _;
    }

    constructor(LotteryParams memory params) {
        factory = msg.sender;

        if (params.usdcToken == address(0)) revert InvalidUSDC();
        if (params.entropy == address(0)) revert InvalidEntropy();
        if (params.entropyProvider == address(0)) revert InvalidProvider();
        if (params.feeRecipient == address(0)) revert InvalidFeeRecipient();
        if (params.creator == address(0)) revert InvalidCreator();
        if (params.finalizer == address(0) || params.guardian == address(0)) revert ZeroAddress();
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

        uint256 minEntry = (params.minPurchaseAmount == 0) ? 1 : uint256(params.minPurchaseAmount);
        uint256 requiredMinPrice = Math.ceilDiv(MIN_NEW_RANGE_COST_BASE, minEntry);
        if (params.ticketPrice < requiredMinPrice) revert BatchTooCheap();

        usdcToken = IERC20(params.usdcToken);
        entropy = IEntropyV2(params.entropy);
        entropyProvider = params.entropyProvider;
        callbackGasLimit = params.callbackGasLimit;

        feeRecipient = params.feeRecipient;
        protocolFeePercent = params.protocolFeePercent;
        creator = params.creator;

        finalizer = params.finalizer;
        guardian = params.guardian;

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

    function minNewRangeCostAt(uint256 rangeCount) public pure returns (uint256) {
        uint256 tier = rangeCount / RANGE_STEP; // 0..9 when MAX_RANGES=100k
        return MIN_NEW_RANGE_COST_BASE + (tier * RANGE_COST_STEP);
    }

    function minNewRangeCostNow() public view returns (uint256) {
        return minNewRangeCostAt(ticketRanges.length);
    }

    function minTicketsToOpenNewRangeNow() external view returns (uint256) {
        return Math.ceilDiv(minNewRangeCostNow(), ticketPrice);
    }

    function wouldCreateNewRange(address buyer) public view returns (bool) {
        uint256 len = ticketRanges.length;
        return (len == 0 || ticketRanges[len - 1].buyer != buyer);
    }

    function getRangePolicy()
        external
        pure
        returns (
            uint256 maxRanges,
            uint256 rangeStep,
            uint256 baseCost,
            uint256 costStep
        )
    {
        return (MAX_RANGES, RANGE_STEP, MIN_NEW_RANGE_COST_BASE, RANGE_COST_STEP);
    }

    function getRangeTierInfo()
        external
        view
        returns (
            uint256 rangeCount,
            uint256 tier,
            uint256 minCostToCreateNewRange,
            uint256 nextTierAtRangeCount,
            uint256 rangesUntilNextTier
        )
    {
        rangeCount = ticketRanges.length;
        tier = rangeCount / RANGE_STEP;
        minCostToCreateNewRange = minNewRangeCostAt(rangeCount);
        nextTierAtRangeCount = (tier + 1) * RANGE_STEP;
        if (nextTierAtRangeCount > MAX_RANGES) nextTierAtRangeCount = MAX_RANGES;
        rangesUntilNextTier = (rangeCount >= nextTierAtRangeCount) ? 0 : (nextTierAtRangeCount - rangeCount);
    }

    function getTicketRangesCount() external view returns (uint256) {
        return ticketRanges.length;
    }

    function getRangeAt(uint256 index)
        external
        view
        returns (address buyer, uint96 lowerBound, uint96 upperBound, uint96 size)
    {
        uint256 len = ticketRanges.length;
        if (index >= len) revert TooManyRanges(); // reuse existing error to avoid new ones

        TicketRange storage tr = ticketRanges[index];
        buyer = tr.buyer;
        upperBound = tr.upperBound;
        lowerBound = (index == 0) ? 0 : ticketRanges[index - 1].upperBound;
        size = upperBound - lowerBound;
    }

    function getRangesWithBounds(uint256 start, uint256 limit)
        external
        view
        returns (address[] memory buyers, uint96[] memory lowerBounds, uint96[] memory upperBounds)
    {
        uint256 n = ticketRanges.length;
        if (start >= n || limit == 0) return (new address, new uint96, new uint96);

        uint256 end = start + limit;
        if (end > n) end = n;

        uint256 size = end - start;
        buyers = new address[](size);
        lowerBounds = new uint96[](size);
        upperBounds = new uint96[](size);

        for (uint256 i = 0; i < size; i++) {
            uint256 idx = start + i;
            TicketRange storage tr = ticketRanges[idx];
            buyers[i] = tr.buyer;
            upperBounds[i] = tr.upperBound;
            lowerBounds[i] = (idx == 0) ? 0 : ticketRanges[idx - 1].upperBound;
        }
    }

    function findRangeForTicket(uint256 ticketIndex) external view returns (uint256 rangeIndex, address buyer) {
        uint256 sold = getSold();
        if (ticketIndex >= sold) revert AccountingMismatch();
        rangeIndex = _findRangeIndex(ticketIndex);
        buyer = ticketRanges[rangeIndex].buyer;
    }

    function _findRangeIndex(uint256 winningTicket) internal view returns (uint256) {
        uint256 low = 0;
        uint256 high = ticketRanges.length - 1;
        while (low < high) {
            uint256 mid = low + (high - low) / 2;
            if (ticketRanges[mid].upperBound > winningTicket) high = mid;
            else low = mid + 1;
        }
        return low;
    }

    function getState()
        external
        view
        returns (
            Status _status,
            uint64 _createdAt,
            uint64 _deadline,
            uint256 _sold,
            uint256 _ticketRevenue,
            uint64 _entropyRequestId,
            uint64 _drawingRequestedAt,
            address _winner
        )
    {
        _status = status;
        _createdAt = createdAt;
        _deadline = deadline;
        _sold = getSold();
        _ticketRevenue = ticketRevenue;
        _entropyRequestId = entropyRequestId;
        _drawingRequestedAt = drawingRequestedAt;
        _winner = winner;
    }

    function getSummary()
        external
        view
        returns (
            Status _status,
            string memory _name,
            address _creator,
            address _usdc,
            uint64 _createdAt,
            uint64 _deadline,
            uint256 _ticketPrice,
            uint256 _winningPot,
            uint64 _minTickets,
            uint64 _maxTickets,
            uint32 _minPurchaseAmount,
            uint256 _sold,
            uint256 _ticketRevenue,
            address _winner,
            uint64 _entropyRequestId,
            uint64 _drawingRequestedAt,
            address _feeRecipient,
            uint256 _protocolFeePercent,
            address _finalizer,
            address _guardian
        )
    {
        _status = status;
        _name = name;
        _creator = creator;
        _usdc = address(usdcToken);
        _createdAt = createdAt;
        _deadline = deadline;
        _ticketPrice = ticketPrice;
        _winningPot = winningPot;
        _minTickets = minTickets;
        _maxTickets = maxTickets;
        _minPurchaseAmount = minPurchaseAmount;
        _sold = getSold();
        _ticketRevenue = ticketRevenue;
        _winner = winner;
        _entropyRequestId = entropyRequestId;
        _drawingRequestedAt = drawingRequestedAt;
        _feeRecipient = feeRecipient;
        _protocolFeePercent = protocolFeePercent;
        _finalizer = finalizer;
        _guardian = guardian;
    }

    function getUserStats(address user)
        external
        view
        returns (
            uint256 ownedTickets,
            uint256 claimable,
            bool isWinner,
            bool canRefundTickets,
            bool canWithdraw
        )
    {
        ownedTickets = ticketsOwned[user];
        claimable = claimableFunds[user];
        isWinner = (winner != address(0) && user == winner);
        canRefundTickets = (status == Status.Canceled && ownedTickets > 0);
        canWithdraw = (claimable > 0);
    }

    function getActions(address user)
        external
        view
        returns (
            bool canBuy,
            bool canFinalize,
            bool canHatch,
            bool canRefundTickets,
            bool canWithdraw
        )
    {
        canBuy = (status == Status.Open && block.timestamp < deadline && user != creator);
        canFinalize = isFinalizable();
        canHatch = isHatchOpen();
        canRefundTickets = (status == Status.Canceled && ticketsOwned[user] > 0);
        canWithdraw = (claimableFunds[user] > 0);
    }

    function getOdds(address user)
        external
        view
        returns (uint256 sold, uint256 userTickets, uint256 oddsBps)
    {
        sold = getSold();
        userTickets = ticketsOwned[user];
        if (sold == 0 || userTickets == 0) return (sold, userTickets, 0);

        if (userTickets > sold) userTickets = sold;

        oddsBps = Math.mulDiv(userTickets, 10_000, sold);
        if (oddsBps > 10_000) oddsBps = 10_000;
    }

    function getProgress()
        external
        view
        returns (
            uint256 sold,
            uint64 _minTickets,
            uint64 _maxTickets,
            uint256 remainingToMin,
            uint256 remainingToMax,
            uint256 secondsLeft,
            bool isExpired
        )
    {
        sold = getSold();
        _minTickets = minTickets;
        _maxTickets = maxTickets;

        remainingToMin = (sold >= _minTickets) ? 0 : (uint256(_minTickets) - sold);

        if (_maxTickets == 0) {
            remainingToMax = 0;
        } else {
            remainingToMax = (sold >= _maxTickets) ? 0 : (uint256(_maxTickets) - sold);
        }

        if (block.timestamp >= deadline) {
            secondsLeft = 0;
            isExpired = true;
        } else {
            secondsLeft = uint256(deadline) - block.timestamp;
            isExpired = false;
        }
    }

    function getAccounting()
        external
        view
        returns (uint256 contractBalance, uint256 reservedUSDC, uint256 unreservedUSDC, uint256 _winningPot, uint256 _ticketRevenue)
    {
        contractBalance = usdcToken.balanceOf(address(this));
        reservedUSDC = totalReservedUSDC;
        unreservedUSDC = (contractBalance > reservedUSDC) ? (contractBalance - reservedUSDC) : 0;
        _winningPot = winningPot;
        _ticketRevenue = ticketRevenue;
    }

    function quoteBuy(address buyer, uint256 count)
        external
        view
        returns (
            uint256 totalCost,
            bool createsNewRange,
            uint256 currentMinNewRangeCost,
            bool meetsNewRangeMinCost,
            uint256 minTicketsToOpenNewRange,
            uint256 postSold,
            uint256 postRangeCount
        )
    {
        totalCost = ticketPrice * count;
        createsNewRange = wouldCreateNewRange(buyer);

        currentMinNewRangeCost = minNewRangeCostNow();
        meetsNewRangeMinCost = (!createsNewRange) || (totalCost >= currentMinNewRangeCost);

        minTicketsToOpenNewRange = Math.ceilDiv(currentMinNewRangeCost, ticketPrice);

        uint256 sold = getSold();
        postSold = sold + count;

        uint256 ranges = ticketRanges.length;
        postRangeCount = createsNewRange ? (ranges + 1) : ranges;
    }

    function getLatestRange()
        external
        view
        returns (bool exists, address buyer, uint96 lowerBound, uint96 upperBound, uint96 size, uint256 rangeIndex)
    {
        uint256 len = ticketRanges.length;
        if (len == 0) return (false, address(0), 0, 0, 0, 0);

        rangeIndex = len - 1;
        TicketRange storage tr = ticketRanges[rangeIndex];
        exists = true;
        buyer = tr.buyer;
        upperBound = tr.upperBound;
        lowerBound = (rangeIndex == 0) ? 0 : ticketRanges[rangeIndex - 1].upperBound;
        size = upperBound - lowerBound;
    }

    function isFinalizable() public view returns (bool) {
        if (status != Status.Open) return false;
        if (entropyRequestId != 0) return false;
        uint256 sold = getSold();
        bool isFull = (maxTickets > 0 && sold >= maxTickets);
        bool isExpired = (block.timestamp >= deadline);
        return (isFull || isExpired);
    }

    function isHatchOpen() public view returns (bool) {
        return (status == Status.Drawing && block.timestamp > uint256(drawingRequestedAt) + HATCH_DELAY);
    }

    function quoteEntropyFee() external view returns (uint256) {
        return entropy.getFeeV2(callbackGasLimit);
    }

    function confirmFunding() external onlyFactory {
        if (status != Status.FundingPending) revert NotFundingPending();

        uint256 bal = usdcToken.balanceOf(address(this));
        if (bal < winningPot) revert FundingMismatch();

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

        bool returning = (ticketRanges.length > 0 && ticketRanges[ticketRanges.length - 1].buyer == msg.sender);

        if (!returning) {
            if (ticketRanges.length >= MAX_RANGES) revert TooManyRanges();
            uint256 minCost = minNewRangeCostAt(ticketRanges.length);
            if (totalCost < minCost) revert BatchTooCheap();
        }

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

    function finalize() external payable nonReentrant onlyFinalizer {
        if (status != Status.Open) revert LotteryNotOpen();
        if (entropyRequestId != 0) revert RequestPending();

        uint256 sold = getSold();
        bool isFull = (maxTickets > 0 && sold >= maxTickets);
        bool isExpired = (block.timestamp >= deadline);

        if (!isFull && !isExpired) revert NotReadyToFinalize();

        if (isExpired && sold < minTickets) {
            if (msg.value != 0) revert WrongEntropyFee();
            _cancelAndRefundCreator("Min tickets not reached");
            return;
        }

        if (sold == 0) revert NoParticipants();

        status = Status.Drawing;
        soldAtDrawing = sold;
        drawingRequestedAt = uint64(block.timestamp);
        selectedProvider = entropyProvider;

        uint256 fee = entropy.getFeeV2(callbackGasLimit);
        if (msg.value != fee) revert WrongEntropyFee();

        bytes32 requestSalt = keccak256(abi.encodePacked(address(this), sold, block.timestamp));
        uint64 requestId = entropy.requestV2{value: fee}(entropyProvider, requestSalt, callbackGasLimit);
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

    function forceCancelStuck() external nonReentrant onlyGuardianOrFinalizer {
        if (status != Status.Drawing) revert NotDrawing();
        if (block.timestamp <= drawingRequestedAt + HATCH_DELAY) revert EarlyCancellationRequest();

        emit EmergencyRecovery();
        _cancelAndRefundCreator("Emergency Recovery");
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
        address w = ticketRanges[_findRangeIndex(winningIndex)].buyer;

        winner = w;
        status = Status.Completed;

        uint256 feePot = Math.mulDiv(winningPot, protocolFeePercent, 100);
        uint256 feeRev = Math.mulDiv(ticketRevenue, protocolFeePercent, 100);

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

    function claimTicketRefund() external nonReentrant {
        if (status != Status.Canceled) revert NotCanceled();

        uint256 tix = ticketsOwned[msg.sender];
        if (tix == 0) revert NothingToRefund();

        uint256 refund = tix * ticketPrice;
        ticketsOwned[msg.sender] = 0;

        if (totalReservedUSDC < refund) revert AccountingMismatch();
        totalReservedUSDC -= refund;

        usdcToken.safeTransfer(msg.sender, refund);

        emit PrizeAllocated(msg.sender, refund, 3);
        emit TicketRefundClaimed(msg.sender, refund);
    }

    function withdrawFunds() external nonReentrant {
        uint256 amount = claimableFunds[msg.sender];
        if (amount == 0) revert NothingToClaim();

        claimableFunds[msg.sender] = 0;

        if (totalReservedUSDC < amount) revert AccountingMismatch();
        totalReservedUSDC -= amount;

        usdcToken.safeTransfer(msg.sender, amount);
        emit FundsClaimed(msg.sender, amount);
    }

    function getSold() public view returns (uint256) {
        uint256 len = ticketRanges.length;
        return len == 0 ? 0 : ticketRanges[len - 1].upperBound;
    }
}