// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";

contract LotteryRegistry is Ownable2Step {
    error ZeroAddress();
    error NotRegistrar();
    error AlreadyRegistered();
    error InvalidTypeId();
    error NotContract();
    error RegistrarAlreadySet();

    event RegistrarLocked(address indexed registrar);
    event LotteryRegistered(uint256 indexed index, uint256 indexed typeId, address indexed lottery, address creator);

    /// @notice The only address allowed to register lotteries (your deployer). Set once, then locked forever.
    address public registrar;

    address[] public allLotteries;
    mapping(address => uint256) public typeIdOf;     // 0 = not registered
    mapping(address => address) public creatorOf;
    mapping(address => uint64) public registeredAt;
    mapping(uint256 => address[]) internal lotteriesByType;

    modifier onlyRegistrar() {
        if (msg.sender != registrar) revert NotRegistrar();
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
    }

    /// @notice One-time setup: lock registrar and permanently renounce ownership in the same tx.
    function setRegistrarOnceAndRenounce(address _registrar) external onlyOwner {
        if (_registrar == address(0)) revert ZeroAddress();
        if (registrar != address(0)) revert RegistrarAlreadySet();

        registrar = _registrar;
        emit RegistrarLocked(_registrar);

        // Removes all owner power forever.
        renounceOwnership();
    }

    /// @notice Kept for compatibility with your deployer check.
    function isRegistrar(address who) external view returns (bool) {
        return who != address(0) && who == registrar;
    }

    function registerLottery(uint256 typeId, address lottery, address creator) external onlyRegistrar {
        if (lottery == address(0) || creator == address(0)) revert ZeroAddress();
        if (typeId == 0) revert InvalidTypeId();
        if (typeIdOf[lottery] != 0) revert AlreadyRegistered();
        if (lottery.code.length == 0) revert NotContract();

        allLotteries.push(lottery);
        typeIdOf[lottery] = typeId;
        creatorOf[lottery] = creator;
        registeredAt[lottery] = uint64(block.timestamp);

        lotteriesByType[typeId].push(lottery);

        emit LotteryRegistered(allLotteries.length - 1, typeId, lottery, creator);
    }

    function isRegisteredLottery(address lottery) external view returns (bool) {
        return typeIdOf[lottery] != 0;
    }

    function getAllLotteriesCount() external view returns (uint256) {
        return allLotteries.length;
    }

    function getLotteriesByTypeCount(uint256 typeId) external view returns (uint256) {
        return lotteriesByType[typeId].length;
    }

    function getLotteryByTypeAtIndex(uint256 typeId, uint256 index) external view returns (address) {
        return lotteriesByType[typeId][index];
    }

    function getAllLotteries(uint256 start, uint256 limit) external view returns (address[] memory page) {
        uint256 n = allLotteries.length;
        if (start >= n || limit == 0) return new address;

        uint256 end = start + limit;
        if (end > n) end = n;

        page = new address[](end - start);
        for (uint256 i = start; i < end; i++) {
            page[i - start] = allLotteries[i];
        }
    }

    function getLotteriesByType(uint256 typeId, uint256 start, uint256 limit)
        external
        view
        returns (address[] memory page)
    {
        address[] storage arr = lotteriesByType[typeId];
        uint256 n = arr.length;
        if (start >= n || limit == 0) return new address;

        uint256 end = start + limit;
        if (end > n) end = n;

        page = new address[](end - start);
        for (uint256 i = start; i < end; i++) {
            page[i - start] = arr[i];
        }
    }
}