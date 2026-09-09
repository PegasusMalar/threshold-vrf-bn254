// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Subscription} from "../../src/Subscription.sol";

/// @notice Attacks on the arithmetic that decides who owns what.
contract AccountingAttackTest is Test {
    Subscription internal subs;
    address internal coordinator = makeAddr("coordinator");
    address internal owner = makeAddr("owner");
    uint256 internal subId;

    function setUp() public {
        subs = new Subscription(coordinator);
        vm.prank(owner);
        subId = subs.createSubscription();
    }

    /// Balances are `uint96` and `msg.value` is not. A deposit that does not
    /// fit has to be refused, not silently wrapped: the coin arrives either
    /// way, and a truncated credit is the difference between an expensive
    /// mistake and an unrecoverable one.
    function test_a_deposit_too_large_for_the_balance_is_refused_not_truncated() public {
        uint256 tooMuch = uint256(type(uint96).max) + 1;
        vm.deal(owner, tooMuch);

        vm.expectRevert(Subscription.DepositTooLarge.selector);
        vm.prank(owner);
        subs.fundSubscription{value: tooMuch}(subId);

        (uint96 balance,) = subs.accountOf(subId);
        assertEq(balance, 0, "the account was credited anyway");
        assertEq(address(subs).balance, 0, "the contract kept the coin");
    }

    /// The boundary itself still works.
    function test_a_deposit_of_exactly_the_maximum_is_accepted() public {
        uint256 most = uint256(type(uint96).max);
        vm.deal(owner, most);

        vm.prank(owner);
        subs.fundSubscription{value: most}(subId);

        (uint96 balance,) = subs.accountOf(subId);
        assertEq(balance, type(uint96).max);
    }

    /// A second deposit that would overflow the balance must revert rather than
    /// wrap. Checked arithmetic already does this; the test pins it, because
    /// the cast above is the kind of thing that gets "simplified" back.
    function test_a_deposit_that_would_overflow_the_balance_reverts() public {
        vm.deal(owner, type(uint96).max);
        vm.prank(owner);
        subs.fundSubscription{value: type(uint96).max}(subId);

        vm.deal(owner, 1);
        vm.expectRevert();
        vm.prank(owner);
        subs.fundSubscription{value: 1}(subId);
    }
}
