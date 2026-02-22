// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @dev Minimal interface the Registry uses to query the registrar (deployer).
interface ICreatorSource {
    function creatorOfLottery(address lottery) external view returns (address);
}

contract LotteryRegistry is Ownable2Step {
    error ZeroAddress();
    error NotRegistrar();
    error AlreadyRegistered();
    error InvalidTypeId();
    error NotContract();

    // Option B integrity errors (registrar is source of truth)
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

    // Optional provenance: who registered this lottery
    mapping(address => address) public registrarOf;

    modifier onlyRegistrar() {
        if (!isRegistrar[msg.sender]) revert NotRegistrar();
        _;
    }

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
    }

    /// @notice Owner can add/remove registrar(s) at any time (affects only NEW registrations).
    function setRegistrar(address registrar, bool authorized) external onlyOwner {
        if (authorized && registrar == address(0)) revert ZeroAddress();
        isRegistrar[registrar] = authorized;
        emit RegistrarSet(registrar, authorized);
    }

    /// @notice Registrar registers a lottery. Creator is READ from the registrar (deployer), not the lottery.
    function registerLottery(uint256 typeId, address lottery) external onlyRegistrar {
        if (lottery == address(0)) revert ZeroAddress();
        if (typeId == 0) revert InvalidTypeId();
        if (typeIdOf[lottery] != 0) revert AlreadyRegistered();
        if (lottery.code.length == 0) revert NotContract();

        address creator = _readCreatorFromRegistrar(msg.sender, lottery);

        allLotteries.push(lottery);
        typeIdOf[lottery] = typeId;
        creatorOf[lottery] = creator;
        registeredAt[lottery] = uint64(block.timestamp);
        registrarOf[lottery] = msg.sender;

        lotteriesByType[typeId].push(lottery);

        emit LotteryRegistered(allLotteries.length - 1, typeId, lottery, creator);
    }

    /// @dev Reads creator from the registrar (trusted deployer).
    ///      Using try/catch keeps the registry resilient if the registrar reverts unexpectedly.
    function _readCreatorFromRegistrar(address registrar, address lottery) internal view returns (address creator) {
        try ICreatorSource(registrar).creatorOfLottery(lottery) returns (address c) {
            creator = c;
        } catch {
            revert CreatorQueryFailed();
        }

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

    /// @notice Single-call record incl. registrar provenance.
    function getLotteryRecord(address lottery)
        external
        view
        returns (
            uint256 typeId,
            address creator,
            uint64 registeredAtTs,
            bool isRegistered,
            address registrar
        )
    {
        typeId = typeIdOf[lottery];
        creator = creatorOf[lottery];
        registeredAtTs = registeredAt[lottery];
        isRegistered = (typeId != 0);
        registrar = registrarOf[lottery];
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

    /// @notice Batch fetch registry info + registrar provenance.
    function getLotteriesInfoWithRegistrars(address[] calldata lotteries)
        external
        view
        returns (
            uint256[] memory typeIds,
            address[] memory creators,
            uint64[] memory registeredAtTs,
            address[] memory registrars
        )
    {
        uint256 n = lotteries.length;
        typeIds = new uint256[](n);
        creators = new address[](n);
        registeredAtTs = new uint64[](n);
        registrars = new address[](n);

        for (uint256 i = 0; i < n; i++) {
            address lot = lotteries[i];
            typeIds[i] = typeIdOf[lot];
            creators[i] = creatorOf[lot];
            registeredAtTs[i] = registeredAt[lot];
            registrars[i] = registrarOf[lot];
        }
    }

    /// @notice Batch counts by typeId (indexer/UI helper).
    function getLotteriesCountByType(uint256[] calldata typeIds)
        external
        view
        returns (uint256[] memory counts)
    {
        uint256 n = typeIds.length;
        counts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            counts[i] = lotteriesByType[typeIds[i]].length;
        }
    }

    function getAllLotteriesPageInfo(uint256 start, uint256 limit)
        external
        view
        returns (
            address[] memory lotteries,
            uint256[] memory typeIds,
            address[] memory creators,
            uint64[] memory timestamps,
            address[] memory registrars
        )
    {
        uint256 n = allLotteries.length;
        if (start >= n || limit == 0) {
            return (new address[](0), new uint256[](0), new address[](0), new uint64[](0), new address[](0));
        }

        uint256 end = start + limit;
        if (end > n) end = n;

        uint256 m = end - start;
        lotteries = new address[](m);
        typeIds = new uint256[](m);
        creators = new address[](m);
        timestamps = new uint64[](m);
        registrars = new address[](m);

        for (uint256 i = 0; i < m; i++) {
            address lot = allLotteries[start + i];
            lotteries[i] = lot;
            typeIds[i] = typeIdOf[lot];
            creators[i] = creatorOf[lot];
            timestamps[i] = registeredAt[lot];
            registrars[i] = registrarOf[lot];
        }
    }

    function getLotteriesByTypePageInfo(uint256 typeId, uint256 start, uint256 limit)
        external
        view
        returns (
            address[] memory lotteries,
            address[] memory creators,
            uint64[] memory timestamps,
            address[] memory registrars
        )
    {
        address[] storage arr = lotteriesByType[typeId];
        uint256 n = arr.length;
        if (start >= n || limit == 0) {
            return (new address[](0), new address[](0), new uint64[](0), new address[](0));
        }

        uint256 end = start + limit;
        if (end > n) end = n;

        uint256 m = end - start;
        lotteries = new address[](m);
        creators = new address[](m);
        timestamps = new uint64[](m);
        registrars = new address[](m);

        for (uint256 i = 0; i < m; i++) {
            address lot = arr[start + i];
            lotteries[i] = lot;
            creators[i] = creatorOf[lot];
            timestamps[i] = registeredAt[lot];
            registrars[i] = registrarOf[lot];
        }
    }

    function areRegistrars(address[] calldata addrs) external view returns (bool[] memory out) {
        uint256 n = addrs.length;
        out = new bool[](n);
        for (uint256 i = 0; i < n; i++) out[i] = isRegistrar[addrs[i]];
    }
}