/// The writes of Správa → Služby (0050), bundled so a widget test can drive
/// the whole screen — the generator, the assign sheet, the seasons, the
/// reminder switch — without the backend. Same idea as
/// `PublicOverviewScreen.save` and `ClubsScreen`'s callbacks, one object
/// instead of eight constructor parameters.
library;

import '../../../data/providers.dart';
import '../../../domain/models.dart';

class DutyAdminApi {
  const DutyAdminApi({
    this.generate = Api.dutyGenerate,
    this.savePeriod = Api.dutyPeriodSave,
    this.deletePeriod = Api.dutyPeriodDelete,
    this.deleteUnassigned = Api.dutyPeriodsDeleteUnassigned,
    this.setAssignees = Api.dutySetAssignees,
    this.startSeason = Api.dutySeasonStart,
    this.deleteSeason = Api.dutySeasonDelete,
    this.setReminder = Api.setDutyReminder,
  });

  /// „Vygenerovat…“ — see [Api.dutyGenerate].
  final Future<({int created, int skipped})> Function({
    required Day from,
    required int days,
    required Day until,
  })
  generate;

  /// „Přidat službu“ ([id] null) and „Upravit termín…“ — see
  /// [Api.dutyPeriodSave].
  final Future<String> Function({
    String? id,
    required Day startsOn,
    required Day endsOn,
    String note,
  })
  savePeriod;

  /// „Smazat“ in a period's menu.
  final Future<void> Function(String id) deletePeriod;

  /// „Smazat neobsazené budoucí…“; returns how many went.
  final Future<int> Function(Day from) deleteUnassigned;

  /// The assign sheet's „Uložit“: the period's whole new set of players.
  final Future<void> Function(String periodId, List<String> userIds)
  setAssignees;

  /// „Nová sezóna…“.
  final Future<void> Function(Day startedOn, String name) startSeason;

  /// „Vrátit poslední sezónu“.
  final Future<void> Function(Day startedOn) deleteSeason;

  /// The reminder card: on or off, and the lead in days.
  final Future<void> Function(
    bool enabled,
    int days, {
    required String tenantId,
  })
  setReminder;
}
