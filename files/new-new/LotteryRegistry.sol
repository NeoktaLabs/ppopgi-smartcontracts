// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title LotteryRegistry
 * @notice A minimal, “forever” on-chain registry for lottery instances.
 */
contract LotteryRegistry {
    error NotOwner();
    error ZeroAddress();
    error NotRegistrar();
    error AlreadyRegistered();
    error InvalidTypeId();
    error NotContract();

    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event RegistrarSet(address indexed registrar, bool authorized);
    event LotteryRegistered(uint256 indexed index, uint256 indexed typeId, address indexed lottery, address creator);

    address public owner;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _owner) {
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
        emit OwnershipTransferred(address(0), _owner);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    address[] public allLotteries;
    mapping(address => uint256) public typeIdOf;
    mapping(address => address) public creatorOf;
    mapping(address => uint64) public registeredAt;
    mapping(uint256 => address[]) internal lotteriesByType;
    mapping(address => bool) public isRegistrar;

    modifier onlyRegistrar() {
        if (!isRegistrar[msg.sender]) revert NotRegistrar();
        _;
    }

    function setRegistrar(address registrar, bool authorized) external onlyOwner {
        if (registrar == address(0)) revert ZeroAddress();
        isRegistrar[registrar] = authorized;
        emit RegistrarSet(registrar, authorized);
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
        if (start >= n || limit == 0) return new address[](0);
        uint256 end = start + limit;
        if (end > n) end = n;

        page = new address[](end - start);
        for (uint256 i = start; i < end; i++) {
            page[i - start] = allLotteries[i];
        }
    }

    function getLotteriesByType(uint256 typeId, uint256 start, uint256 limit) external view returns (address[] memory page) {
        address[] storage arr = lotteriesByType[typeId];
        uint256 n = arr.length;
        if (start >= n || limit == 0) return new address[](0);
        uint256 end = start + limit;
        if (end > n) end = n;

        page = new address[](end - start);
        for (uint256 i = start; i < end; i++) {
            page[i - start] = arr[i];
        }
    }
}
