// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./LotteryRegistry.sol";
import "./LotterySingleWinner.sol";

contract SingleWinnerDeployer is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotOwner();
    error ZeroAddress();
    error FeeTooHigh();
    error NotAuthorizedRegistrar(); 
    error InvalidRescueTarget();

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
        address feeRecipient,
        uint256 protocolFeePercent,
        uint64 deadline,
        uint64 minTickets,
        uint64 maxTickets
    );
    
    event ConfigUpdated(address usdc, address entropy, address provider, address feeRecipient, uint256 protocolFeePercent);

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
        if (_owner == address(0) || _registry == address(0) || _safeOwner == address(0) || _usdc == address(0) ||
            _entropy == address(0) || _entropyProvider == address(0) || _feeRecipient == address(0)) revert ZeroAddress();
        
        if (_protocolFeePercent > 20) revert FeeTooHigh();

        owner = _owner;
        registry = LotteryRegistry(_registry);
        safeOwner = _safeOwner;
        usdc = _usdc;
        entropy = _entropy;
        entropyProvider = _entropyProvider;
        feeRecipient = _feeRecipient;
        protocolFeePercent = _protocolFeePercent;

        emit DeployerOwnershipTransferred(address(0), _owner);
        emit ConfigUpdated(_usdc, _entropy, _entropyProvider, _feeRecipient, _protocolFeePercent);
    }

    function setConfig(address _usdc, address _entropy, address _provider, address _fee, uint256 _percent) external onlyOwner {
        if (_usdc == address(0) || _entropy == address(0) || _provider == address(0) || _fee == address(0)) revert ZeroAddress();
        if (_percent > 20) revert FeeTooHigh();
        usdc = _usdc;
        entropy = _entropy;
        entropyProvider = _provider;
        feeRecipient = _fee;
        protocolFeePercent = _percent;
        emit ConfigUpdated(_usdc, _entropy, _provider, _fee, _percent);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit DeployerOwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // Escape hatch: Allows admin to register a lottery if automatic registration failed
    function rescueRegistration(address lotteryAddr, address creator) external onlyOwner {
        if (!registry.isRegistrar(address(this))) revert NotAuthorizedRegistrar();
        if (lotteryAddr == address(0) || creator == address(0)) revert ZeroAddress();
        
        // Safety: ensure it's a contract before calling
        if (lotteryAddr.code.length == 0) revert InvalidRescueTarget();

        try LotterySingleWinner(payable(lotteryAddr)).deployer() returns (address d) {
            if (d != address(this)) revert InvalidRescueTarget();
        } catch {
            revert InvalidRescueTarget();
        }

        try LotterySingleWinner(payable(lotteryAddr)).owner() returns (address o) {
             if (o != safeOwner) revert InvalidRescueTarget();
        } catch {
            revert InvalidRescueTarget();
        }

        registry.registerLottery(SINGLE_WINNER_TYPE_ID, lotteryAddr, creator);
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

        LotterySingleWinner.LotteryParams memory params = LotterySingleWinner.LotteryParams({
            usdcToken: usdc,
            entropy: entropy,
            entropyProvider: entropyProvider,
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

        LotterySingleWinner lot = new LotterySingleWinner(params);

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
            feeRecipient, 
            protocolFeePercent,
            deadline,
            minTickets,
            maxTickets
        );

        // Robustness: Wrap registration in try/catch so deployment succeeds even if registry fails
        try registry.registerLottery(SINGLE_WINNER_TYPE_ID, lotteryAddr, msg.sender) {
            // Success
        } catch {
            emit RegistrationFailed(lotteryAddr, msg.sender);
        }
    }
}