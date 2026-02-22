// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./LotteryRegistry.sol";
import "./SingleWinnerLottery.sol";

contract SingleWinnerDeployer is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error FeeTooHigh();
    error NotAuthorizedRegistrar();
    error InvalidCallbackGasLimit();
    error RegistryRegistrationFailed(bytes lowLevelData);
    error UnknownLottery(); // for creatorOfLottery queries

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

    event FeeConfigUpdated(address indexed feeRecipient, uint256 protocolFeePercent);
    event EntropyConfigUpdated(address indexed entropy, address indexed entropyProvider);

    uint256 public constant SINGLE_WINNER_TYPE_ID = 1;

    LotteryRegistry public immutable registry;

    address public immutable usdc;
    uint32 public immutable callbackGasLimit;

    // ---- mutable configs (only affect NEW lotteries) ----
    address public entropy;
    address public entropyProvider;

    address public feeRecipient;
    uint256 public protocolFeePercent;

    // Option B: deployer is the source of truth for creator
    mapping(address => address) private _creatorOfLottery;

    constructor(
        address initialOwner,
        address _registry,
        address _usdc,
        address _entropy,
        address _entropyProvider,
        uint32 _callbackGasLimit,
        address _feeRecipient,
        uint256 _protocolFeePercent
    ) Ownable(initialOwner) {
        if (
            initialOwner == address(0) ||
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
        callbackGasLimit = _callbackGasLimit;

        entropy = _entropy;
        entropyProvider = _entropyProvider;
        emit EntropyConfigUpdated(_entropy, _entropyProvider);

        feeRecipient = _feeRecipient;
        protocolFeePercent = _protocolFeePercent;
        emit FeeConfigUpdated(_feeRecipient, _protocolFeePercent);
    }

    /// @notice Updates protocol fees for NEW lotteries only.
    function setFeeConfig(address _feeRecipient, uint256 _protocolFeePercent) external onlyOwner {
        if (_feeRecipient == address(0)) revert ZeroAddress();
        if (_protocolFeePercent > 20) revert FeeTooHigh();

        feeRecipient = _feeRecipient;
        protocolFeePercent = _protocolFeePercent;

        emit FeeConfigUpdated(_feeRecipient, _protocolFeePercent);
    }

    /// @notice Updates Entropy contract + provider for NEW lotteries only.
    function setEntropyConfig(address _entropy, address _entropyProvider) external onlyOwner {
        if (_entropy == address(0) || _entropyProvider == address(0)) revert ZeroAddress();
        entropy = _entropy;
        entropyProvider = _entropyProvider;
        emit EntropyConfigUpdated(_entropy, _entropyProvider);
    }

    // =========================
    // Option B creator source
    // =========================

    /// @notice Called by the Registry (Option B) to read creator for a lottery this deployer created.
    function creatorOfLottery(address lottery) external view returns (address) {
        address c = _creatorOfLottery[lottery];
        if (c == address(0)) revert UnknownLottery();
        return c;
    }

    /// @notice Non-reverting getter (UIs/indexers prefer this).
    function getCreatorOfLotteryOrZero(address lottery) external view returns (address creator) {
        return _creatorOfLottery[lottery];
    }

    /// @notice Batch non-reverting creator lookup.
    function getCreatorsForLotteries(address[] calldata lotteries) external view returns (address[] memory creators) {
        uint256 n = lotteries.length;
        creators = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            creators[i] = _creatorOfLottery[lotteries[i]];
        }
    }

    /// @notice Batch lookup with an explicit known flag.
    function getCreatorsForLotteriesWithKnown(address[] calldata lotteries)
        external
        view
        returns (address[] memory creators, bool[] memory known)
    {
        uint256 n = lotteries.length;
        creators = new address[](n);
        known = new bool[](n);

        for (uint256 i = 0; i < n; i++) {
            address c = _creatorOfLottery[lotteries[i]];
            creators[i] = c;
            known[i] = (c != address(0));
        }
    }

    // =========================
    // UX helpers
    // =========================

    function getCurrentConfig()
        external
        view
        returns (
            address registryAddr,
            address usdcToken,
            address entropyAddr,
            address entropyProviderAddr,
            uint32 cbGasLimit,
            address currentFeeRecipient,
            uint256 currentProtocolFeePercent
        )
    {
        return (
            address(registry),
            usdc,
            entropy,
            entropyProvider,
            callbackGasLimit,
            feeRecipient,
            protocolFeePercent
        );
    }

    function previewLotteryParams(
        address creator,
        string calldata name,
        uint256 ticketPrice,
        uint256 winningPot,
        uint64 minTickets,
        uint64 maxTickets,
        uint64 durationSeconds,
        uint32 minPurchaseAmount
    ) public view returns (SingleWinnerLottery.LotteryParams memory params) {
        params = SingleWinnerLottery.LotteryParams({
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

    function isDeployerAuthorized() external view returns (bool) {
        return registry.isRegistrar(address(this));
    }

    function quoteCreate(uint256 winningPot) public view returns (address usdcToken, uint256 usdcAmountToTransfer) {
        return (usdc, winningPot);
    }

    function previewCreate(
        address creator,
        string calldata name,
        uint256 ticketPrice,
        uint256 winningPot,
        uint64 minTickets,
        uint64 maxTickets,
        uint64 durationSeconds,
        uint32 minPurchaseAmount
    )
        external
        view
        returns (address usdcToken, uint256 usdcToTransfer, SingleWinnerLottery.LotteryParams memory params)
    {
        (usdcToken, usdcToTransfer) = quoteCreate(winningPot);
        params = previewLotteryParams(
            creator, name, ticketPrice, winningPot, minTickets, maxTickets, durationSeconds, minPurchaseAmount
        );
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

        address entropySnapshot = entropy;
        address entropyProviderSnapshot = entropyProvider;
        address feeRecipientSnapshot = feeRecipient;
        uint256 protocolFeePercentSnapshot = protocolFeePercent;

        SingleWinnerLottery.LotteryParams memory params = SingleWinnerLottery.LotteryParams({
            usdcToken: usdc,
            entropy: entropySnapshot,
            entropyProvider: entropyProviderSnapshot,
            callbackGasLimit: callbackGasLimit,
            feeRecipient: feeRecipientSnapshot,
            protocolFeePercent: protocolFeePercentSnapshot,
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

        // Option B: record creator mapping BEFORE registry registration
        _creatorOfLottery[lotteryAddr] = msg.sender;

        IERC20(usdc).safeTransferFrom(msg.sender, lotteryAddr, winningPot);
        lot.confirmFunding();

        uint64 dl = lot.deadline();

        try registry.registerLottery(SINGLE_WINNER_TYPE_ID, lotteryAddr) {
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
            entropySnapshot,
            entropyProviderSnapshot,
            callbackGasLimit,
            feeRecipientSnapshot,
            protocolFeePercentSnapshot,
            dl,
            minTickets,
            maxTickets
        );
    }
}