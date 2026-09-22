/// Skupiny hráčů (0044): members book and cancel trainings for each other.
/// Pure Dart over `player_group_members` rows — RLS hands the app its own
/// group, its own invites, and (to an admin) the whole alley.
library;

enum GroupStatus { invited, member }

class GroupRow {
  const GroupRow({
    required this.groupId,
    required this.userId,
    required this.status,
    this.invitedBy,
  });

  final String groupId;
  final String userId;
  final GroupStatus status;
  final String? invitedBy;

  factory GroupRow.fromJson(Map<String, dynamic> json) => GroupRow(
        groupId: json['group_id'] as String,
        userId: json['user_id'] as String,
        status: json['status'] == 'member'
            ? GroupStatus.member
            : GroupStatus.invited,
        invitedBy: json['invited_by'] as String?,
      );
}

/// An invite waiting for the signed-in player.
class GroupInvite {
  const GroupInvite({required this.groupId, this.invitedBy});
  final String groupId;
  final String? invitedBy;
}

class MyGroup {
  const MyGroup({
    this.groupId,
    this.memberIds = const [],
    this.invitedIds = const [],
    this.invitesForMe = const [],
  });

  static const none = MyGroup();

  /// Null outside any group.
  final String? groupId;

  /// Everyone in it, me included.
  final List<String> memberIds;

  /// Invited to MY group, not yet accepted.
  final List<String> invitedIds;

  /// Other groups inviting me.
  final List<GroupInvite> invitesForMe;

  /// Whom I may book and cancel for (the group without me).
  Set<String> matesOf(String me) => {
        for (final id in memberIds)
          if (id != me) id,
      };

  bool get isEmpty => groupId == null && invitesForMe.isEmpty;
}

MyGroup myGroupOf(List<GroupRow> rows, String me) {
  final groupId = [
    for (final r in rows)
      if (r.userId == me && r.status == GroupStatus.member) r.groupId,
  ].firstOrNull;
  return MyGroup(
    groupId: groupId,
    memberIds: [
      for (final r in rows)
        if (groupId != null &&
            r.groupId == groupId &&
            r.status == GroupStatus.member)
          r.userId,
    ],
    invitedIds: [
      for (final r in rows)
        if (groupId != null &&
            r.groupId == groupId &&
            r.status == GroupStatus.invited)
          r.userId,
    ],
    invitesForMe: [
      for (final r in rows)
        if (r.userId == me && r.status == GroupStatus.invited)
          GroupInvite(groupId: r.groupId, invitedBy: r.invitedBy),
    ],
  );
}

/// Správa → Hráči: every member with the OTHER members of their group.
Map<String, List<String>> groupMatesByPlayer(List<GroupRow> rows) {
  final byGroup = <String, List<String>>{};
  for (final r in rows) {
    if (r.status == GroupStatus.member) {
      (byGroup[r.groupId] ??= []).add(r.userId);
    }
  }
  return {
    for (final members in byGroup.values)
      for (final id in members) id: [for (final o in members) if (o != id) o],
  };
}
