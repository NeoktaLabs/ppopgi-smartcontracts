// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./LotteryRegistry.sol";
import "./LotterySingleWinnerV2.sol";

contract SingleWinnerDeployerV2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotOwner();
    error ZeroAddress();
    error FeeTooHigh();
    error NotAuthorizedRegistrar();
    error InvalidCallbackGasLimit();

    event DeployerOwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event RegistrationFailed(address indexed lottery, address indexed creator);

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

    event ConfigUpdated(address usdc, address entropy, address provider, uint32 callbackGasLimit, address feeRecipient, uint256 protocolFeePercent);

    // Default chosen for Etherlink production
    uint32 public constant DEFAULT_CALLBACK_GAS_LIMIT = 500_000;

    address public owner;
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    LotteryRegistry public immutable registry;
    address public immutable safeOwner;
    uint256 public constant SINGLE_WINNER_TYPE_ID = 1;

    address public usdc;
    address public entropy;
    address public entropyProvider;
    uint32 public callbackGasLimit;
    address public feeRecipient;
    uint256 public protocolFeePercent;

    constructor(
        address _owner,
        address _registry,
        address _safeOwner,
        address _usdc,
        address _entropy,
        address _entropyProvider,
        address _feeRecipient,
        uint256 _protocolFeePercent
    ) {
        if (
            _owner == address(0) || _registry == address(0) || _safeOwner == address(0) ||
            _usdc == address(0) || _entropy == address(0) || _entropyProvider == address(0) || _feeRecipient == address(0)
        ) revert ZeroAddress();

        if (_protocolFeePercent > 20) revert FeeTooHigh();

        owner = _owner;
        registry = LotteryRegistry(_registry);
        safeOwner = _safeOwner;

        usdc = _usdc;
        entropy = _entropy;
        entropyProvider = _entropyProvider;
        callbackGasLimit = DEFAULT_CALLBACK_GAS_LIMIT;
        feeRecipient = _feeRecipient;
        protocolFeePercent = _protocolFeePercent;

        emit DeployerOwnershipTransferred(address(0), _owner);
        emit ConfigUpdated(_usdc, _entropy, _entropyProvider, callbackGasLimit, _feeRecipient, _protocolFeePercent);
    }

    function setConfig(
        address _usdc,
        address _entropy,
        address _provider,
        uint32 _callbackGasLimit,
        address _fee,
        uint256 _percent
    ) external onlyOwner {
        if (_usdc == address(0) || _entropy == address(0) || _provider == address(0) || _fee == address(0)) revert ZeroAddress();
        if (_percent > 20) revert FeeTooHigh();
        if (_callbackGasLimit == 0) revert InvalidCallbackGasLimit();

        usdc = _usdc;
        entropy = _entropy;
        entropyProvider = _provider;
        callbackGasLimit = _callbackGasLimit;
        feeRecipient = _fee;
        protocolFeePercent = _percent;

        emit ConfigUpdated(_usdc, _entropy, _provider, _callbackGasLimit, _fee, _percent);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit DeployerOwnershipTransferred(owner, newOwner);
        owner = newOwner;
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

        LotterySingleWinnerV2.LotteryParams memory params = LotterySingleWinnerV2.LotteryParams({
            usdcToken: usdc,
            entropy: entropy,
            entropyProvider: entropyProvider,
            callbackGasLimit: callbackGasLimit, // <- 500,000 by default
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

        LotterySingleWinnerV2 lot = new LotterySingleWinnerV2(params);

        IERC20(usdc).safeTransferFrom(msg.sender, address(lot), winningPot);
        lot.confirmFunding();
        lot.transferOwnership(safeOwner);

        lotteryAddr = address(lot);
        uint64 deadline = lot.deadline();

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
            deadline,
            minTickets,
            maxTickets
        );

        try registry.registerLottery(SINGLE_WINNER_TYPE_ID, lotteryAddr, msg.sender) {
        } catch {
            emit RegistrationFailed(lotteryAddr, msg.sender);
        }
    }
}