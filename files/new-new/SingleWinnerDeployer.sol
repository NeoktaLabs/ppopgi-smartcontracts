// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@pythnetwork/entropy-sdk-solidity/IEntropyV2.sol";

import "./LotteryRegistry.sol";
import "./SingleWinnerLottery.sol";

contract SingleWinnerDeployer is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotOwner();
    error ZeroAddress();
    error FeeTooHigh();
    error NotAuthorizedRegistrar();
    error InvalidCallbackGasLimit();

    error RegistryRegistrationFailed(bytes lowLevelData);

    event DeployerOwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    event LotteryDeployed(
        address indexed lottery,
        address indexed creator,
        uint256 winningPot,
        uint256 ticketPrice,
        string name,
        address usdc,
        address entropy,
        address entropyProvider,
        uint32 callbackGasLimit,
        address feeRecipient,
        uint256 protocolFeePercent,
        uint64 deadline,
        uint64 minTickets,
        uint64 maxTickets
    );

    event ConfigUpdated(
        address usdc,
        address entropy,
        address provider,
        uint32 callbackGasLimit,
        address feeRecipient,
        uint256 protocolFeePercent
    );

    event TrustedRolesUpdated(address finalizer, address guardian);
    event RaffleRoles(address indexed raffle, address indexed finalizer, address indexed guardian);

    // ---- changed: make admin private to remove auto-generated owner() getter ----
    address private _admin;

    modifier onlyOwner() {
        if (msg.sender != _admin) revert NotOwner();
        _;
    }

    /// @notice Optional UX getter (NOT named owner()).
    function admin() external view returns (address) {
        return _admin;
    }

    LotteryRegistry public immutable registry;
    uint256 public constant SINGLE_WINNER_TYPE_ID = 1;

    address public usdc;
    address public entropy;
    address public entropyProvider;
    uint32 public callbackGasLimit;
    address public feeRecipient;
    uint256 public protocolFeePercent;
    address public finalizer;
    address public guardian;

    uint256 public constant MAX_BATCH_BUY = 1000;
    uint256 public constant MIN_NEW_RANGE_COST = 1_000_000;
    uint256 public constant MAX_TICKET_PRICE = 100_000 * 1e6;
    uint256 public constant MAX_POT_SIZE = 10_000_000 * 1e6;
    uint64 public constant MAX_DURATION = 365 days;

    constructor(
        address _owner,
        address _registry,
        address _usdc,
        address _entropy,
        address _entropyProvider,
        uint32 _callbackGasLimit,
        address _feeRecipient,
        uint256 _protocolFeePercent,
        address _finalizer,
        address _guardian
    ) {
        if (
            _owner == address(0) ||
            _registry == address(0) ||
            _usdc == address(0) ||
            _entropy == address(0) ||
            _entropyProvider == address(0) ||
            _feeRecipient == address(0) ||
            _finalizer == address(0) ||
            _guardian == address(0)
        ) revert ZeroAddress();

        if (_protocolFeePercent > 20) revert FeeTooHigh();
        if (_callbackGasLimit == 0) revert InvalidCallbackGasLimit();

        _admin = _owner;
        registry = LotteryRegistry(_registry);

        usdc = _usdc;
        entropy = _entropy;
        entropyProvider = _entropyProvider;
        callbackGasLimit = _callbackGasLimit;
        feeRecipient = _feeRecipient;
        protocolFeePercent = _protocolFeePercent;

        finalizer = _finalizer;
        guardian = _guardian;

        emit DeployerOwnershipTransferred(address(0), _owner);
        emit ConfigUpdated(_usdc, _entropy, _entropyProvider, _callbackGasLimit, _feeRecipient, _protocolFeePercent);
        emit TrustedRolesUpdated(_finalizer, _guardian);
    }

    function setConfig(
        address _usdc,
        address _entropy,
        address _provider,
        uint32 _callbackGasLimit,
        address _feeRecipient,
        uint256 _protocolFeePercent,
        address _finalizer,
        address _guardian
    ) external onlyOwner {
        if (
            _usdc == address(0) ||
            _entropy == address(0) ||
            _provider == address(0) ||
            _feeRecipient == address(0) ||
            _finalizer == address(0) ||
            _guardian == address(0)
        ) revert ZeroAddress();

        if (_protocolFeePercent > 20) revert FeeTooHigh();
        if (_callbackGasLimit == 0) revert InvalidCallbackGasLimit();

        usdc = _usdc;
        entropy = _entropy;
        entropyProvider = _provider;
        callbackGasLimit = _callbackGasLimit;
        feeRecipient = _feeRecipient;
        protocolFeePercent = _protocolFeePercent;

        finalizer = _finalizer;
        guardian = _guardian;

        emit ConfigUpdated(_usdc, _entropy, _provider, _callbackGasLimit, _feeRecipient, _protocolFeePercent);
        emit TrustedRolesUpdated(_finalizer, _guardian);
    }

    // Kept name for compatibility, but it updates _admin.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit DeployerOwnershipTransferred(_admin, newOwner);
        _admin = newOwner;
    }

    function getConfig()
        external
        view
        returns (
            address usdcToken,
            address entropyContract,
            address provider,
            uint32 gasLimit,
            address feeTo,
            uint256 feePercent,
            address _finalizer,
            address _guardian
        )
    {
        return (usdc, entropy, entropyProvider, callbackGasLimit, feeRecipient, protocolFeePercent, finalizer, guardian);
    }

    function quoteEntropyFee() external view returns (uint256 fee) {
        return IEntropyV2(entropy).getFeeV2(callbackGasLimit);
    }

    function minTicketPriceFor(uint32 minPurchaseAmount) public pure returns (uint256) {
        uint256 minEntry = (minPurchaseAmount == 0) ? 1 : uint256(minPurchaseAmount);
        return Math.ceilDiv(MIN_NEW_RANGE_COST, minEntry);
    }

    function validateInputs(
        uint256 ticketPrice,
        uint256 winningPot,
        uint64 minTickets,
        uint64 maxTickets,
        uint64 durationSeconds,
        uint32 minPurchaseAmount
    ) external pure returns (bool ok, bytes32 reason) {
        if (durationSeconds < 600) return (false, "DURATION_TOO_SHORT");
        if (durationSeconds > MAX_DURATION) return (false, "DURATION_TOO_LONG");
        if (ticketPrice == 0 || ticketPrice > MAX_TICKET_PRICE) return (false, "BAD_TICKET_PRICE");
        if (winningPot == 0 || winningPot > MAX_POT_SIZE) return (false, "BAD_POT");
        if (minTickets == 0) return (false, "MIN_TICKETS_ZERO");
        if (minPurchaseAmount > MAX_BATCH_BUY) return (false, "MIN_BUY_TOO_LARGE");
        if (maxTickets != 0 && maxTickets < minTickets) return (false, "MAX_LT_MIN");
        if (ticketPrice < minTicketPriceFor(minPurchaseAmount)) return (false, "BATCH_TOO_CHEAP");
        return (true, bytes32(0));
    }

    function buildParams(
        address creator_,
        string calldata name,
        uint256 ticketPrice,
        uint256 winningPot,
        uint64 minTickets,
        uint64 maxTickets,
        uint64 durationSeconds,
        uint32 minPurchaseAmount
    ) external view returns (SingleWinnerRaffle.LotteryParams memory params) {
        params = SingleWinnerRaffle.LotteryParams({
            usdcToken: usdc,
            entropy: entropy,
            entropyProvider: entropyProvider,
            callbackGasLimit: callbackGasLimit,
            feeRecipient: feeRecipient,
            protocolFeePercent: protocolFeePercent,
            creator: creator_,
            name: name,
            ticketPrice: ticketPrice,
            winningPot: winningPot,
            minTickets: minTickets,
            maxTickets: maxTickets,
            durationSeconds: durationSeconds,
            minPurchaseAmount: minPurchaseAmount,
            finalizer: finalizer,
            guardian: guardian
        });
    }

    function createSingleWinnerLottery(
        string calldata name,
        uint256 ticketPrice,
        uint256 winningPot,
        uint64 minTickets,
        uint64 maxTickets,
        uint64 durationSeconds,
        uint32 minPurchaseAmount
    ) external nonReentrant returns (address lotteryAddr) {
        if (!registry.isRegistrar(address(this))) revert NotAuthorizedRegistrar();

        SingleWinnerRaffle.LotteryParams memory params = SingleWinnerRaffle.LotteryParams({
            usdcToken: usdc,
            entropy: entropy,
            entropyProvider: entropyProvider,
            callbackGasLimit: callbackGasLimit,
            feeRecipient: feeRecipient,
            protocolFeePercent: protocolFeePercent,
            creator: msg.sender,
            name: name,
            ticketPrice: ticketPrice,
            winningPot: winningPot,
            minTickets: minTickets,
            maxTickets: maxTickets,
            durationSeconds: durationSeconds,
            minPurchaseAmount: minPurchaseAmount,
            finalizer: finalizer,
            guardian: guardian
        });

        SingleWinnerRaffle lot = new SingleWinnerRaffle(params);

        IERC20(usdc).safeTransferFrom(msg.sender, address(lot), winningPot);
        lot.confirmFunding();

        lotteryAddr = address(lot);
        uint64 raffleDeadline = lot.deadline();

        try registry.registerLottery(SINGLE_WINNER_TYPE_ID, lotteryAddr, msg.sender) {
            // ok
        } catch (bytes memory data) {
            revert RegistryRegistrationFailed(data);
        }

        emit LotteryDeployed(
            lotteryAddr,
            msg.sender,
            winningPot,
            ticketPrice,
            name,
            usdc,
            entropy,
            entropyProvider,
            callbackGasLimit,
            feeRecipient,
            protocolFeePercent,
            raffleDeadline,
            minTickets,
            maxTickets
        );

        emit RaffleRoles(lotteryAddr, finalizer, guardian);
    }
}