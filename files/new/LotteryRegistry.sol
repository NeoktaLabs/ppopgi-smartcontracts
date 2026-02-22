// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";

contract LotteryRegistry is Ownable2Step {
    error ZeroAddress();
    error NotRegistrar();
    error AlreadyRegistered();
    error InvalidTypeId();
    error NotContract();

    // Creator integrity errors
    error CreatorQueryFailed();
    error InvalidCreator();

    event RegistrarSet(address indexed registrar, bool authorized);
    event LotteryRegistered(uint256 indexed index, uint256 indexed typeId, address indexed lottery, address creator);

    address[] public allLotteries;
    mapping(address => uint256) public typeIdOf; // 0 = not registered
    mapping(address => address) public creatorOf;
    mapping(address => uint64) public registeredAt;
    mapping(uint256 => address[]) internal lotteriesByType;
    mapping(address => bool) public isRegistrar;

    modifier onlyRegistrar() {
        if (!isRegistrar[msg.sender]) revert NotRegistrar();
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
    }

    /// @notice Owner can add/remove deployer(s) at any time (affects only NEW registrations).
    function setRegistrar(address registrar, bool authorized) external onlyOwner {
        if (authorized && registrar == address(0)) revert ZeroAddress();
        isRegistrar[registrar] = authorized;
        emit RegistrarSet(registrar, authorized);
    }

    /// @notice Registrar registers a lottery. Creator is READ from the lottery contract (creator()).
    function registerLottery(uint256 typeId, address lottery) external onlyRegistrar {
        if (lottery == address(0)) revert ZeroAddress();
        if (typeId == 0) revert InvalidTypeId();
        if (typeIdOf[lottery] != 0) revert AlreadyRegistered();
        if (lottery.code.length == 0) revert NotContract();

        address creator = _readCreator(lottery);

        allLotteries.push(lottery);
        typeIdOf[lottery] = typeId;
        creatorOf[lottery] = creator;
        registeredAt[lottery] = uint64(block.timestamp);

        lotteriesByType[typeId].push(lottery);

        emit LotteryRegistered(allLotteries.length - 1, typeId, lottery, creator);
    }

    /// @dev Reads `creator()` from a lottery with bounded-gas staticcall to avoid griefing.
    function _readCreator(address lottery) internal view returns (address creator) {
        (bool ok, bytes memory ret) = lottery.staticcall{gas: 25_000}(hex"02fb0c5e");
        if (!ok || ret.length < 32) revert CreatorQueryFailed();

        creator = abi.decode(ret, (address));
        if (creator == address(0)) revert InvalidCreator();
    }

    // =========================
    // Basic helpers
    // =========================

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

    function getLotteryInfo(address lottery)
        external
        view
        returns (uint256 typeId, address creator, uint64 registeredAtTs, bool isRegistered)
    {
        typeId = typeIdOf[lottery];
        creator = creatorOf[lottery];
        registeredAtTs = registeredAt[lottery];
        isRegistered = (typeId != 0);
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

    function getLotteriesByType(uint256 typeId, uint256 start, uint256 limit)
        external
        view
        returns (address[] memory page)
    {
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

    // =========================
    // Added UX/indexer helpers
    // =========================

    function getLotteriesInfo(address[] calldata lotteries)
        external
        view
        returns (uint256[] memory typeIds, address[] memory creators, uint64[] memory registeredAtTs)
    {
        uint256 n = lotteries.length;
        typeIds = new uint256[](n);
        creators = new address[](n);
        registeredAtTs = new uint64[](n);

        for (uint256 i = 0; i < n; i++) {
            address lot = lotteries[i];
            typeIds[i] = typeIdOf[lot];
            creators[i] = creatorOf[lot];
            registeredAtTs[i] = registeredAt[lot];
        }
    }

    function getAllLotteriesPageInfo(uint256 start, uint256 limit)
        external
        view
        returns (
            address[] memory lotteries,
            uint256[] memory typeIds,
            address[] memory creators,
            uint64[] memory timestamps
        )
    {
        uint256 n = allLotteries.length;
        if (start >= n || limit == 0) {
            return (new address[](0), new uint256[](0), new address[](0), new uint64[](0));
        }

        uint256 end = start + limit;
        if (end > n) end = n;

        uint256 m = end - start;
        lotteries = new address[](m);
        typeIds = new uint256[](m);
        creators = new address[](m);
        timestamps = new uint64[](m);

        for (uint256 i = 0; i < m; i++) {
            address lot = allLotteries[start + i];
            lotteries[i] = lot;
            typeIds[i] = typeIdOf[lot];
            creators[i] = creatorOf[lot];
            timestamps[i] = registeredAt[lot];
        }
    }

    function getLotteriesByTypePageInfo(uint256 typeId, uint256 start, uint256 limit)
        external
        view
        returns (address[] memory lotteries, address[] memory creators, uint64[] memory timestamps)
    {
        address[] storage arr = lotteriesByType[typeId];
        uint256 n = arr.length;
        if (start >= n || limit == 0) {
            return (new address[](0), new address[](0), new uint64[](0));
        }

        uint256 end = start + limit;
        if (end > n) end = n;

        uint256 m = end - start;
        lotteries = new address[](m);
        creators = new address[](m);
        timestamps = new uint64[](m);

        for (uint256 i = 0; i < m; i++) {
            address lot = arr[start + i];
            lotteries[i] = lot;
            creators[i] = creatorOf[lot];
            timestamps[i] = registeredAt[lot];
        }
    }

    function areRegistrars(address[] calldata addrs) external view returns (bool[] memory out) {
        uint256 n = addrs.length;
        out = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = isRegistrar[addrs[i]];
        }
    }
}
