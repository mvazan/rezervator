import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/groups.dart';

void main() {
  GroupRow row(String group, String user, GroupStatus status,
          {String? by}) =>
      GroupRow(groupId: group, userId: user, status: status, invitedBy: by);

  final rows = [
    row('g1', 'petr', GroupStatus.member),
    row('g1', 'jana', GroupStatus.member),
    row('g1', 'karel', GroupStatus.invited, by: 'petr'),
    row('g2', 'lenka', GroupStatus.member),
    row('g2', 'petr', GroupStatus.invited, by: 'lenka'),
  ];

  test('GroupRow.fromJson reads the table row', () {
    final r = GroupRow.fromJson({
      'group_id': 'g1',
      'user_id': 'u1',
      'status': 'invited',
      'invited_by': 'u2',
      'tenant_id': 't',
      'created_at': '2026-09-22T10:00:00Z',
    });
    expect(r.groupId, 'g1');
    expect(r.userId, 'u1');
    expect(r.status, GroupStatus.invited);
    expect(r.invitedBy, 'u2');
  });

  test('my group: its members, its pending invites, and invites for me', () {
    final g = myGroupOf(rows, 'petr');
    expect(g.groupId, 'g1');
    expect(g.memberIds.toSet(), {'petr', 'jana'});
    expect(g.invitedIds, ['karel']);
    expect(g.invitesForMe.single.groupId, 'g2');
    expect(g.invitesForMe.single.invitedBy, 'lenka');
    expect(g.matesOf('petr'), {'jana'});
    expect(g.isEmpty, isFalse);
  });

  test('outside any group: only invites', () {
    final g = myGroupOf(rows, 'karel');
    expect(g.groupId, isNull);
    expect(g.memberIds, isEmpty);
    expect(g.matesOf('karel'), isEmpty);
    expect(g.invitesForMe.single.groupId, 'g1');
    expect(g.isEmpty, isFalse, reason: 'a pending invite is something to show');
  });

  test('nothing at all is empty', () {
    expect(myGroupOf(const [], 'x').isEmpty, isTrue);
    expect(MyGroup.none.isEmpty, isTrue);
  });

  test('the admin view: each member with the others of the group', () {
    final byPlayer = groupMatesByPlayer(rows);
    expect(byPlayer['petr'], ['jana']);
    expect(byPlayer['jana'], ['petr']);
    expect(byPlayer['lenka'], isEmpty);
    expect(byPlayer.containsKey('karel'), isFalse, reason: 'invited is not in');
  });
}
