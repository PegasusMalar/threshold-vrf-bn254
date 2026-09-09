// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Subscription
/// @notice Holds the ETH that pays for VRF requests. The coordinator holds none.
///
/// @dev Not a subscription in the recurring sense, whatever the name suggests:
///      it is a prepaid account. Money goes in, is drawn down per request, and
///      what is left can be taken back at any time.
///
///      The external surface follows the convention integrators already know,
///      function for function, so an existing dashboard works here. Where it
///      departs from that convention the reason is marked below.
///
///      Money moves in three steps, and the middle one is what makes the whole
///      thing honest: funds are *reserved* when a request is created, *settled*
///      when it is fulfilled, and *released* if it times out. Without the
///      reservation an owner could drain the balance in the window between
///      request and fulfillment, and the operators would have signed for free.
///
///      There is no owner and no admin: `coordinator` is immutable and the only
///      privileged caller, and all it can do is move a subscription's own money
///      between reserved and spent.
contract Subscription {
    error NotCoordinator();
    error NotSubscriptionOwner();
    error NotPendingOwner();
    error NoSuchSubscription();
    error InsufficientBalance();
    /// @notice More coin than a balance can hold was sent in one deposit
    error DepositTooLarge();
    error FundsReserved();
    error NothingToWithdraw();
    error TransferFailed();
    error IndexOutOfRange();
    error SubscriptionIdTooLarge();

    /* ------------------------------------------------------------------ */
    /*  Names, argument order and indexing follow the established           */
    /*  convention, so an existing decoder or subgraph lines up without     */
    /*  being rewritten.                                                    */
    /* ------------------------------------------------------------------ */

    event SubscriptionCreated(uint256 indexed subId, address owner);
    event SubscriptionFundedWithNative(
        uint256 indexed subId, uint256 oldNativeBalance, uint256 newNativeBalance
    );
    event SubscriptionCanceled(
        uint256 indexed subId, address to, uint256 amountLink, uint256 amountNative
    );
    event SubscriptionConsumerAdded(uint256 indexed subId, address consumer);
    event SubscriptionConsumerRemoved(uint256 indexed subId, address consumer);
    event SubscriptionOwnerTransferRequested(uint256 indexed subId, address from, address to);
    event SubscriptionOwnerTransferred(uint256 indexed subId, address from, address to);

    /// @dev No counterpart in the convention this interface follows, where the
    ///      only way to get money out is to close the account.
    event SubscriptionWithdrawal(uint256 indexed subId, address to, uint256 amount);

    /// @dev The reserved portion is ours to expose; the convention hides it.
    event Reserved(uint256 indexed subId, uint96 amount);
    event Released(uint256 indexed subId, uint96 amount);
    event Settled(uint256 indexed subId, uint96 amount, address indexed payee);
    event Withdrawn(address indexed payee, address indexed to, uint96 amount);

    struct Account {
        address owner;
        uint96 balance;
        uint96 reserved;
    }

    /// @dev Counted rather than inferred from `reserved`. At the free tier the
    ///      price is zero, so nothing is ever reserved, and a subscription with
    ///      requests in flight would otherwise look idle — and be cancellable.
    struct Counters {
        uint64 total;
        uint64 pending;
    }

    /// @notice The only address allowed to reserve, settle or release funds
    address public immutable coordinator;

    uint64 private _lastSubId;
    mapping(uint64 => Account) private _accounts;
    mapping(uint64 => address) private _pendingOwners;
    mapping(uint64 => mapping(address => bool)) private _consumers;
    /// @dev Kept alongside the mapping so `getSubscription` can hand a manager
    ///      the whole list in one call rather than making it replay logs.
    mapping(uint64 => address[]) private _consumerList;
    mapping(uint64 => Counters) private _counters;
    mapping(address => uint96) private _withdrawable;

    /// @dev Live subscription ids, for `getActiveSubscriptionIds`.
    uint64[] private _activeIds;
    mapping(uint64 => uint256) private _activeIndex; // 1-based; 0 means absent

    modifier onlyCoordinator() {
        if (msg.sender != coordinator) revert NotCoordinator();
        _;
    }

    modifier onlyOwnerOf(uint256 subId) {
        if (_accounts[_narrow(subId)].owner != msg.sender) revert NotSubscriptionOwner();
        _;
    }

    constructor(address coordinator_) {
        coordinator = coordinator_;
    }

    /* ------------------------------ owner API ----------------------------- */

    /// @notice Open a prepaid account. Not a subscription in the recurring
    ///         sense: nothing is charged by time, only per request.
    function createSubscription() external returns (uint256 subId) {
        uint64 id = ++_lastSubId;
        _accounts[id].owner = msg.sender;
        _activeIds.push(id);
        _activeIndex[id] = _activeIds.length;
        emit SubscriptionCreated(id, msg.sender);
        return id;
    }

    /// @notice Top up. Deliberately open to anyone: a sponsor paying for an
    ///         integrator's usage is a normal thing to want, and it is also how
    ///         the free tier works — we fund the integrator's account ourselves.
    function fundSubscriptionWithNative(uint256 subId) public payable {
        uint64 id = _narrow(subId);
        Account storage account = _accounts[id];
        if (account.owner == address(0)) revert NoSuchSubscription();

        // Balances are uint96 and msg.value is not. Refused rather than
        // truncated: the coin arrives either way, so a narrowing cast here
        // would credit a fraction of a deposit and keep the rest, with nothing
        // on chain to say it happened. The addition below is checked, which
        // covers the balance overflowing across several deposits; this covers
        // one deposit that does not fit on its own.
        if (msg.value > type(uint96).max) revert DepositTooLarge();

        uint96 oldBalance = account.balance;
        // casting to 'uint96' is safe because the line above rejects anything
        // that would not fit
        // forge-lint: disable-next-line(unsafe-typecast)
        account.balance = oldBalance + uint96(msg.value);
        emit SubscriptionFundedWithNative(subId, oldBalance, account.balance);
    }

    /// @notice Same thing, shorter name. The suffix exists only because the
    ///         convention distinguishes token funding from native funding; here
    ///         the chain's own coin is the only option.
    function fundSubscription(uint256 subId) external payable {
        fundSubscriptionWithNative(subId);
    }

    /// @notice Take back part of the deposit without closing the account.
    ///
    /// @dev The alternative — closing the account — invalidates the id every
    ///      integration was deployed with, which makes "I overfunded" an
    ///      expensive mistake. Here you top up generously, use what you use, and
    ///      take the rest back; what is reserved behind open requests stays put.
    function withdrawFromSubscription(uint256 subId, uint96 amount, address to)
        external
        onlyOwnerOf(subId)
    {
        uint64 id = _narrow(subId);
        Account storage account = _accounts[id];
        if (account.balance - account.reserved < amount) revert InsufficientBalance();

        account.balance -= amount;
        emit SubscriptionWithdrawal(subId, to, amount);
        _send(to, amount);
    }

    function addConsumer(uint256 subId, address consumer) external onlyOwnerOf(subId) {
        uint64 id = _narrow(subId);
        if (_consumers[id][consumer]) return;
        _consumers[id][consumer] = true;
        _consumerList[id].push(consumer);
        emit SubscriptionConsumerAdded(subId, consumer);
    }

    function removeConsumer(uint256 subId, address consumer) external onlyOwnerOf(subId) {
        uint64 id = _narrow(subId);
        if (!_consumers[id][consumer]) return;
        _consumers[id][consumer] = false;

        address[] storage list = _consumerList[id];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == consumer) {
                list[i] = list[list.length - 1];
                list.pop();
                break;
            }
        }
        emit SubscriptionConsumerRemoved(subId, consumer);
    }

    /// @notice Close the account and take the remainder.
    /// @dev Refuses while requests are open — requests, not money: at the free
    ///      tier there is nothing reserved and an owner still must not be able
    ///      to walk away mid-request.
    function cancelSubscription(uint256 subId, address to) external onlyOwnerOf(subId) {
        uint64 id = _narrow(subId);
        Account storage account = _accounts[id];
        if (account.reserved != 0 || _counters[id].pending != 0) revert FundsReserved();

        uint96 amount = account.balance;
        delete _accounts[id];
        delete _consumerList[id];
        delete _counters[id];
        // Otherwise a standing offer could be accepted afterwards and resurrect
        // a subscription that no longer exists, under a new owner.
        delete _pendingOwners[id];
        _deactivate(id);

        // The token amount is always zero: this VRF takes only native coin.
        emit SubscriptionCanceled(subId, to, 0, amount);
        _send(to, amount);
    }

    /// @notice Offer the account to `newOwner`, who must accept it.
    /// @dev Two steps because one is unforgiving: a single mistyped address
    ///      would take the balance and every integration pointed at this
    ///      account with it, permanently. Offering `address(0)` withdraws a
    ///      standing offer.
    function requestSubscriptionOwnerTransfer(uint256 subId, address newOwner)
        external
        onlyOwnerOf(subId)
    {
        _pendingOwners[_narrow(subId)] = newOwner;
        emit SubscriptionOwnerTransferRequested(subId, msg.sender, newOwner);
    }

    /// @notice Take ownership of an account that was offered to you.
    function acceptSubscriptionOwnerTransfer(uint256 subId) external {
        uint64 id = _narrow(subId);
        if (_pendingOwners[id] != msg.sender || msg.sender == address(0)) revert NotPendingOwner();

        address previous = _accounts[id].owner;
        _accounts[id].owner = msg.sender;
        delete _pendingOwners[id];
        emit SubscriptionOwnerTransferred(subId, previous, msg.sender);
    }

    /* --------------------------- coordinator API -------------------------- */

    function reserve(uint256 subId, uint96 amount) external onlyCoordinator {
        uint64 id = _narrow(subId);
        Account storage account = _accounts[id];
        if (account.balance - account.reserved < amount) revert InsufficientBalance();

        account.reserved += amount;
        _counters[id].total += 1;
        _counters[id].pending += 1;
        emit Reserved(subId, amount);
    }

    function release(uint256 subId, uint96 amount) external onlyCoordinator {
        uint64 id = _narrow(subId);
        _accounts[id].reserved -= amount;
        _closeOne(id);
        emit Released(subId, amount);
    }

    /// @notice Spend a reservation and credit `payee`.
    /// @dev Credit, not transfer: paying out inside fulfillment would hand a
    ///      reentrancy point to whoever relays the transaction.
    function settle(uint256 subId, uint96 amount, address payee) external onlyCoordinator {
        uint64 id = _narrow(subId);
        Account storage account = _accounts[id];
        account.reserved -= amount;
        account.balance -= amount;
        _withdrawable[payee] += amount;
        _closeOne(id);
        emit Settled(subId, amount, payee);
    }

    function _closeOne(uint64 id) private {
        Counters storage counters = _counters[id];
        if (counters.pending != 0) counters.pending -= 1;
    }

    /* ------------------------------ payouts ------------------------------- */

    /// @notice For operators, to collect what fulfilling requests earned them.
    function withdraw(address to) external {
        uint96 amount = _withdrawable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        _withdrawable[msg.sender] = 0;
        emit Withdrawn(msg.sender, to, amount);
        _send(to, amount);
    }

    /* -------------------------------- views ------------------------------- */

    /// @notice Everything a subscription manager needs, in one call.
    ///
    /// @dev Field for field as the convention defines it, token balance
    ///      included — which is always zero here, because this VRF is paid for
    ///      in the chain's own coin and nothing else. The reserved portion has
    ///      no place in that shape and is exposed by `accountOf` instead:
    ///      putting it in slot two would silently show a ported dashboard a
    ///      number that means something entirely different.
    function getSubscription(uint256 subId)
        external
        view
        returns (
            uint96 tokenBalance,
            uint96 nativeBalance,
            uint64 reqCount,
            address subOwner,
            address[] memory consumers
        )
    {
        uint64 id = _narrow(subId);
        Account storage account = _accounts[id];
        return (0, account.balance, _counters[id].total, account.owner, _consumerList[id]);
    }

    /// @notice Page through the live accounts. `maxCount` of 0 means "to the end".
    function getActiveSubscriptionIds(uint256 startIndex, uint256 maxCount)
        external
        view
        returns (uint256[] memory ids)
    {
        uint256 total = _activeIds.length;
        if (startIndex >= total) revert IndexOutOfRange();

        uint256 endIndex = startIndex + maxCount;
        if (endIndex > total || maxCount == 0) endIndex = total;

        ids = new uint256[](endIndex - startIndex);
        for (uint256 i = 0; i < ids.length; i++) {
            ids[i] = _activeIds[startIndex + i];
        }
    }

    function activeSubscriptionCount() external view returns (uint256) {
        return _activeIds.length;
    }

    /// @notice Whether this account has requests that have not closed.
    function pendingRequestExists(uint256 subId) external view returns (bool) {
        return _counters[_narrow(subId)].pending != 0;
    }

    /// @notice How many requests this account has open right now.
    function pendingRequestCount(uint256 subId) external view returns (uint64) {
        return _counters[_narrow(subId)].pending;
    }

    function ownerOf(uint256 subId) external view returns (address) {
        return _accounts[_narrow(subId)].owner;
    }

    /// @notice Who has been offered this account, if anyone.
    function pendingOwnerOf(uint256 subId) external view returns (address) {
        return _pendingOwners[_narrow(subId)];
    }

    /// @notice Balance and the part of it locked behind open requests.
    function accountOf(uint256 subId) external view returns (uint96 balance, uint96 reserved) {
        Account storage account = _accounts[_narrow(subId)];
        return (account.balance, account.reserved);
    }

    /// @notice What can be spent or withdrawn right now.
    function availableOf(uint256 subId) external view returns (uint96) {
        Account storage account = _accounts[_narrow(subId)];
        return account.balance - account.reserved;
    }

    function isConsumer(uint256 subId, address consumer) external view returns (bool) {
        return _consumers[_narrow(subId)][consumer];
    }

    function withdrawableOf(address payee) external view returns (uint96) {
        return _withdrawable[payee];
    }

    function lastSubId() external view returns (uint256) {
        return _lastSubId;
    }

    /* ------------------------------ internals ----------------------------- */

    /// @dev Ids are `uint256` on the surface, so that consumer code written
    ///      against the usual convention compiles unchanged, and `uint64` in
    ///      storage, where they pack into a request alongside the consumer and
    ///      the word count. They are handed out sequentially, so the narrowing
    ///      can only fail on an id this contract never issued.
    function _narrow(uint256 subId) private pure returns (uint64) {
        if (subId > type(uint64).max) revert SubscriptionIdTooLarge();
        // casting to 'uint64' is safe because the line above rejects anything
        // that would not fit
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(subId);
    }

    function _deactivate(uint64 id) private {
        uint256 position = _activeIndex[id];
        if (position == 0) return;

        uint256 last = _activeIds.length;
        if (position != last) {
            uint64 moved = _activeIds[last - 1];
            _activeIds[position - 1] = moved;
            _activeIndex[moved] = position;
        }
        _activeIds.pop();
        delete _activeIndex[id];
    }

    function _send(address to, uint96 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
