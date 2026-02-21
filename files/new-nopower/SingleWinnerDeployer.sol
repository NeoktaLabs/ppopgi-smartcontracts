// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./LotteryRegistry.sol";
import "./SingleWinnerLottery.sol";

contract SingleWinnerDeployer is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error FeeTooHigh();
    error NotAuthorizedRegistrar();
    error InvalidCallbackGasLimit();
    error RegistryRegistrationFailed(bytes lowLevelData);

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

    uint256 public constant SINGLE_WINNER_TYPE_ID = 1;

    LotteryRegistry public immutable registry;

    address public immutable usdc;
    address public immutable entropy;
    address public immutable entropyProvider;
    uint32 public immutable callbackGasLimit;

    // fee config is immutable (no owner power; only affects NEW lotteries like before)
    address public immutable feeRecipient;
    uint256 public immutable protocolFeePercent;

    constructor(
        address _registry,
        address _usdc,
        address _entropy,
        address _entropyProvider,
        uint32 _callbackGasLimit,
        address _feeRecipient,
        uint256 _protocolFeePercent
    ) {
        if (
            _registry == address(0) ||
            _usdc == address(0) ||
            _entropy == address(0) ||
            _entropyProvider == address(0) ||
            _feeRecipient == address(0)
        ) revert ZeroAddress();

        if (_protocolFeePercent > 20) revert FeeTooHigh();
        if (_callbackGasLimit == 0) revert InvalidCallbackGasLimit();

        registry = LotteryRegistry(_registry);

        usdc = _usdc;
        entropy = _entropy;
        entropyProvider = _entropyProvider;
        callbackGasLimit = _callbackGasLimit;

        feeRecipient = _feeRecipient;
        protocolFeePercent = _protocolFeePercent;
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
        // keep your existing gating semantics
        if (!registry.isRegistrar(address(this))) revert NotAuthorizedRegistrar();

        SingleWinnerLottery.LotteryParams memory params = SingleWinnerLottery.LotteryParams({
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

        SingleWinnerLottery lot = new SingleWinnerLottery(params);
        lotteryAddr = address(lot);

        IERC20(usdc).safeTransferFrom(msg.sender, lotteryAddr, winningPot);
        lot.confirmFunding();

        uint64 dl = lot.deadline();

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
            dl,
            minTickets,
            maxTickets
        );
    }
}