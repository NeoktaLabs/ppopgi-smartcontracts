// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./LotteryRegistry.sol";
import "./SingleWinnerDeployer.sol";

contract Bootstrap {
    event Deployed(address registry, address deployer);

    function deployAll(
        address usdc,
        address entropy,
        address entropyProvider,
        uint32 callbackGasLimit,
        address feeRecipient,
        uint256 protocolFeePercent
    ) external returns (address registryAddr, address deployerAddr) {
        // 1) deploy registry
        LotteryRegistry registry = new LotteryRegistry();
        registryAddr = address(registry);

        // 2) deploy deployer pointing to that registry
        SingleWinnerDeployer deployer = new SingleWinnerDeployer(
            registryAddr,
            usdc,
            entropy,
            entropyProvider,
            callbackGasLimit,
            feeRecipient,
            protocolFeePercent
        );
        deployerAddr = address(deployer);

        // 3) lock registrar forever to the deployer (same tx)
        registry.lockRegistrar(deployerAddr);

        emit Deployed(registryAddr, deployerAddr);
    }
}