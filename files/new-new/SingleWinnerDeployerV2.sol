// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./RafflesRegistry.sol";
import "./SingleWinnerRaffle.sol";

/**
 * @title SingleWinnerDeployer
 * @notice Factory for deploying SingleWinnerRaffle instances and registering them in RafflesRegistry.
 *         Config changes here affect ONLY future raffles.
 *
 * UX/RPC helpers added:
 * - "quote" functions for frontends/bots (fee, min buy, and min ticketPrice constraints)
 * - single-call config getter
 * - helper to build the exact params for a given creator+inputs (UI preview)
 *
 * @dev Updated for "no owner raffles":
 *      - Removed safeOwner and any transferOwnership() call on the raffle.
 */
contract SingleWinnerDeployer is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotOwner();
    error ZeroAddress();
    error FeeTooHigh();
    error NotAuthorizedRegistrar();
    error InvalidCallbackGasLimit();

    error RegistryRegistrationFailed(bytes lowLevelData);

    event DeployerOwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    // Kept name for backward compatibility with your indexers/consumers.
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

    address public owner;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    RafflesRegistry public immutable registry;
    uint256 public constant SINGLE_WINNER_TYPE_ID = 1;

    // Mutable config for FUTURE raffles only
    address public usdc;
    address public entropy;
    address public entropyProvider;
    uint32 public callbackGasLimit;
    address public feeRecipient;
    uint256 public protocolFeePercent;

    // Keep in sync with SingleWinnerRaffle constants (UX quotes)
    uint256 public constant MAX_BATCH_BUY = 1000;
    uint256 public constant MIN_NEW_RANGE_COST = 1_000_000; // 1 USDC (6 decimals)
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
        uint256 _protocolFeePercent
    ) {
        if (
            _owner == address(0) ||
            _registry == address(0) ||
            _usdc == address(0) ||
            _entropy == address(0) ||
            _entropyProvider == address(0) ||
            _feeRecipient == address(0)
        ) revert ZeroAddress();

        if (_protocolFeePercent > 20) revert FeeTooHigh();
        if (_callbackGasLimit == 0) revert InvalidCallbackGasLimit();

        owner = _owner;
        registry = RafflesRegistry(_registry);

        usdc = _usdc;
        entropy = _entropy;
        entropyProvider = _entropyProvider;
        callbackGasLimit = _callbackGasLimit;
        feeRecipient = _feeRecipient;
        protocolFeePercent = _protocolFeePercent;

        emit DeployerOwnershipTransferred(address(0), _owner);
        emit ConfigUpdated(_usdc, _entropy, _entropyProvider, _callbackGasLimit, _feeRecipient, _protocolFeePercent);
    }

    function setConfig(
        address _usdc,
        address _entropy,
        address _provider,
        uint32 _callbackGasLimit,
        address _feeRecipient,
        uint256 _protocolFeePercent
    ) external onlyOwner {
        if (_usdc == address(0) || _entropy == address(0) || _provider == address(0) || _feeRecipient == address(0)) {
            revert ZeroAddress();
        }
        if (_protocolFeePercent > 20) revert FeeTooHigh();
        if (_callbackGasLimit == 0) revert InvalidCallbackGasLimit();

        usdc = _usdc;
        entropy = _entropy;
        entropyProvider = _provider;
        callbackGasLimit = _callbackGasLimit;
        feeRecipient = _feeRecipient;
        protocolFeePercent = _protocolFeePercent;

        emit ConfigUpdated(_usdc, _entropy, _provider, _callbackGasLimit, _feeRecipient, _protocolFeePercent);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit DeployerOwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // -------------------------
    // UX / RPC helper views
    // -------------------------

    /// @notice Single-call read of current factory config (for UIs).
    function getConfig()
        external
        view
        returns (
            address usdcToken,
            address entropyContract,
            address provider,
            uint32 gasLimit,
            address feeTo,
            uint256 feePercent
        )
    {
        return (usdc, entropy, entropyProvider, callbackGasLimit, feeRecipient, protocolFeePercent);
    }

    /// @notice Quote Entropy fee required to finalize (for a raffle deployed with current config).
    function quoteEntropyFee() external view returns (uint256 fee) {
        return IEntropyV2(entropy).getFeeV2(callbackGasLimit);
    }

    /// @notice Min allowed ticketPrice given a minPurchaseAmount (so a new range costs at least 1 USDC).
    function minTicketPriceFor(uint32 minPurchaseAmount) public pure returns (uint256) {
        uint256 minEntry = (minPurchaseAmount == 0) ? 1 : uint256(minPurchaseAmount);
        return (MIN_NEW_RANGE_COST + minEntry - 1) / minEntry; // ceil(1e6/minEntry)
    }

    /// @notice Validates basic bounds for UX (front-end can pre-check and avoid revert).
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

    /// @notice Builds the exact params struct for a given creator+inputs (UI preview / debugging).
    function buildParams(
        address creator,
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
            creator: creator,
            name: name,
            ticketPrice: ticketPrice,
            winningPot: winningPot,
            minTickets: minTickets,
            maxTickets: maxTickets,
            durationSeconds: durationSeconds,
            minPurchaseAmount: minPurchaseAmount
        });
    }

    // -------------------------
    // Deployment
    // -------------------------

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
            minPurchaseAmount: minPurchaseAmount
        });

        SingleWinnerRaffle lot = new SingleWinnerRaffle(params);

        // Fund the pot (USDC) for this specific raffle.
        IERC20(usdc).safeTransferFrom(msg.sender, address(lot), winningPot);

        // Open the raffle; only deployer can confirm.
        lot.confirmFunding();

        lotteryAddr = address(lot);
        uint64 raffleDeadline = lot.deadline();

        // Register in registry (required for your UX / indexer).
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
    }
}