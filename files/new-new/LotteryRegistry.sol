// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title RafflesRegistry
 * @notice A minimal, “forever” on-chain registry for raffle instances.
 *
 * UX/RPC helpers added:
 * - total counts + pagination helpers
 * - batch metadata fetch for a page of raffles (typeId/creator/registeredAt in 1 call)
 * - batch fetch for a page of raffles-by-type (same metadata in 1 call)
 * - index lookup helpers
 */
contract RafflesRegistry {
    error NotOwner();
    error ZeroAddress();
    error NotRegistrar();
    error AlreadyRegistered();
    error InvalidTypeId();
    error NotContract();
    error IndexOutOfBounds();

    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event RegistrarSet(address indexed registrar, bool authorized);

    // Kept name for backward compatibility with your indexers/consumers.
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

    // Storage
    address[] public allLotteries;
    mapping(address => uint256) public typeIdOf;
    mapping(address => address) public creatorOf;
    mapping(address => uint64) public registeredAt;
    mapping(uint256 => address[]) internal lotteriesByType;
    mapping(address => bool) public isRegistrar;

    // Optional: index lookups (UX/indexer-friendly)
    // 0 => "not found" sentinel; stored value is index+1
    mapping(address => uint256) public allIndexPlusOne;
    mapping(uint256 => mapping(address => uint256)) public typeIndexPlusOne;

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

        // all list
        allLotteries.push(lottery);
        uint256 allIndex = allLotteries.length - 1;
        allIndexPlusOne[lottery] = allIndex + 1;

        // metadata
        typeIdOf[lottery] = typeId;
        creatorOf[lottery] = creator;
        uint64 ts = uint64(block.timestamp);
        registeredAt[lottery] = ts;

        // by-type list + index
        lotteriesByType[typeId].push(lottery);
        uint256 typeIndex = lotteriesByType[typeId].length - 1;
        typeIndexPlusOne[typeId][lottery] = typeIndex + 1;

        emit LotteryRegistered(allIndex, typeId, lottery, creator);
    }

    // ---------------------------------------
    // Basic views (kept)
    // ---------------------------------------

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
        address[] storage arr = lotteriesByType[typeId];
        if (index >= arr.length) revert IndexOutOfBounds();
        return arr[index];
    }

    // ---------------------------------------
    // Pagination helpers
    // ---------------------------------------

    /// @notice Returns the computed [start,end) for paging.
    function getAllLotteriesPageBounds(uint256 start, uint256 limit) external view returns (uint256 end, uint256 total) {
        total = allLotteries.length;
        if (start >= total || limit == 0) return (start, total);
        end = start + limit;
        if (end > total) end = total;
    }

    /// @notice Returns the computed [start,end) for paging by type.
    function getLotteriesByTypePageBounds(uint256 typeId, uint256 start, uint256 limit)
        external
        view
        returns (uint256 end, uint256 total)
    {
        total = lotteriesByType[typeId].length;
        if (start >= total || limit == 0) return (start, total);
        end = start + limit;
        if (end > total) end = total;
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

    function getLotteriesByType(uint256 typeId, uint256 start, uint256 limit) external view returns (address[] memory page) {
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

    // ---------------------------------------
    // Batch metadata getters (reduce RPC calls)
    // ---------------------------------------

    /**
     * @notice Batch fetch registry metadata for a page of all raffles.
     * @dev One RPC call returns address + typeId + creator + registeredAt arrays.
     */
    function getAllLotteriesWithMeta(uint256 start, uint256 limit)
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
            return (new address, new uint256, new address, new uint64);
        }

        uint256 end = start + limit;
        if (end > n) end = n;

        uint256 size = end - start;
        lotteries = new address[](size);
        typeIds = new uint256[](size);
        creators = new address[](size);
        timestamps = new uint64[](size);

        for (uint256 i = 0; i < size; i++) {
            address lot = allLotteries[start + i];
            lotteries[i] = lot;
            typeIds[i] = typeIdOf[lot];
            creators[i] = creatorOf[lot];
            timestamps[i] = registeredAt[lot];
        }
    }

    /**
     * @notice Batch fetch registry metadata for a page of raffles within a type.
     */
    function getLotteriesByTypeWithMeta(uint256 typeId, uint256 start, uint256 limit)
        external
        view
        returns (
            address[] memory lotteries,
            address[] memory creators,
            uint64[] memory timestamps
        )
    {
        address[] storage arr = lotteriesByType[typeId];
        uint256 n = arr.length;
        if (start >= n || limit == 0) {
            return (new address, new address, new uint64);
        }

        uint256 end = start + limit;
        if (end > n) end = n;

        uint256 size = end - start;
        lotteries = new address[](size);
        creators = new address[](size);
        timestamps = new uint64[](size);

        for (uint256 i = 0; i < size; i++) {
            address lot = arr[start + i];
            lotteries[i] = lot;
            creators[i] = creatorOf[lot];
            timestamps[i] = registeredAt[lot];
        }
    }

    // ---------------------------------------
    // Index lookup helpers (optional but handy)
    // ---------------------------------------

    /// @notice Returns (found, index) for the raffle in the global list.
    function getAllIndex(address lottery) external view returns (bool found, uint256 index) {
        uint256 v = allIndexPlusOne[lottery];
        if (v == 0) return (false, 0);
        return (true, v - 1);
    }

    /// @notice Returns (found, index) for the raffle in the per-type list.
    function getTypeIndex(uint256 typeId, address lottery) external view returns (bool found, uint256 index) {
        uint256 v = typeIndexPlusOne[typeId][lottery];
        if (v == 0) return (false, 0);
        return (true, v - 1);
    }

    /// @notice Convenience: returns the last registered raffle address (or zero if none).
    function getLatestLottery() external view returns (address) {
        uint256 n = allLotteries.length;
        return n == 0 ? address(0) : allLotteries[n - 1];
    }
}