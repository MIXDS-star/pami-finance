import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/finance/expense_draft.dart';
import '../../core/util/ids.dart';
import '../models.dart';
import 'guard.dart';

/// Budgets, goals, recurring calendar and monthly reports.
class PlanRepository {
  PlanRepository(this._client);
  final SupabaseClient _client;

  String get _uid => _client.auth.currentUser!.id;

  Future<List<Budget>> budgets() => guard(() async {
        final rows = await _client.from('budgets').select('*, budget_categories(category_id)').isFilter('archived_at', null).order('created_at');
        return rows.map(Budget.fromJson).toList();
      });

  Future<List<BudgetStatus>> budgetStatus(DateTime month) => guard(() async {
        final rows = await _client.rpc('budget_status', params: {'p_month': isoDate(month)}) as List;
        return rows.map((r) => BudgetStatus.fromJson(r as Map<String, dynamic>)).toList();
      });

  Future<void> saveBudget({String? id, required String workspaceId, required String name, required String currency,
          int? amountMinor, int? incomeShareBp, required int alertThresholdBp, required List<String> categoryIds}) =>
      guard(() async {
        final values = {
          'name': name.trim(), 'amount_minor': amountMinor, 'income_share_bp': incomeShareBp, 'alert_threshold_bp': alertThresholdBp,
        };
        final String budgetId;
        if (id == null) {
          final row = await _client.from('budgets').insert({
            ...values, 'workspace_id': workspaceId, 'currency': currency, 'created_by': _uid,
            'starts_on': isoDate(DateTime(DateTime.now().year, DateTime.now().month)),
          }).select('id').single();
          budgetId = row['id'] as String;
        } else {
          await _client.from('budgets').update(values).eq('id', id);
          budgetId = id;
          await _client.from('budget_categories').delete().eq('budget_id', id);
        }
        if (categoryIds.isNotEmpty) {
          await _client.from('budget_categories').insert([for (final c in categoryIds) {'budget_id': budgetId, 'category_id': c}]);
        }
      });

  Future<void> archiveBudget(String id) =>
      guard(() => _client.from('budgets').update({'archived_at': DateTime.now().toUtc().toIso8601String()}).eq('id', id));

  Future<List<Goal>> goals() => guard(() async {
        final rows = await _client.from('savings_goals').select().isFilter('archived_at', null).order('priority').order('created_at');
        return rows.map(Goal.fromJson).toList();
      });

  Future<List<GoalProgress>> goalProgress() => guard(() async {
        final rows = await _client.rpc('goal_progress') as List;
        return rows.map((r) => GoalProgress.fromJson(r as Map<String, dynamic>)).toList();
      });

  Future<void> saveGoal({String? id, required String workspaceId, required String kind, required String name,
          required String currency, required int targetMinor, DateTime? targetDate, int? plannedMonthlyMinor, int priority = 2}) =>
      guard(() async {
        final values = {
          'kind': kind, 'name': name.trim(), 'target_minor': targetMinor,
          'target_date': targetDate == null ? null : isoDate(targetDate), 'planned_monthly_minor': plannedMonthlyMinor,
          'priority': priority,
        };
        if (id == null) {
          await _client.from('savings_goals').insert({...values, 'workspace_id': workspaceId, 'currency': currency, 'created_by': _uid});
        } else {
          await _client.from('savings_goals').update(values).eq('id', id);
        }
      });

  Future<void> archiveGoal(String id) =>
      guard(() => _client.from('savings_goals').update({'archived_at': DateTime.now().toUtc().toIso8601String()}).eq('id', id));

  Future<List<Contribution>> contributions(String goalId) => guard(() async {
        final rows = await _client.from('savings_contributions').select().eq('goal_id', goalId).isFilter('deleted_at', null)
            .order('occurred_on', ascending: false);
        return rows.map(Contribution.fromJson).toList();
      });

  Future<void> addContribution(String goalId, int amountMinor, DateTime date, {String? note, String? requestId}) => guard(() =>
      _client.from('savings_contributions').upsert({
        'goal_id': goalId, 'amount_minor': amountMinor, 'occurred_on': isoDate(date), 'note': note,
        'client_request_id': requestId ?? newId(), 'created_by': _uid,
      }, onConflict: 'created_by,client_request_id', ignoreDuplicates: true));

  Future<void> deleteContribution(String id) => guard(() =>
      _client.from('savings_contributions').update({'deleted_at': DateTime.now().toUtc().toIso8601String()}).eq('id', id));

  Future<List<RecurringRule>> recurringRules() => guard(() async {
        final rows = await _client.from('recurring_rules').select().order('anchor_date');
        return rows.map(RecurringRule.fromJson).toList();
      });

  Future<void> saveRecurringRule({String? id, required String workspaceId, required String kind, required String label,
          String? categoryId, required String currency, required int expectedMinor, required String frequency,
          required DateTime anchorDate, bool active = true}) =>
      guard(() async {
        final values = {
          'label': label.trim(), 'category_id': categoryId, 'expected_minor': expectedMinor, 'frequency': frequency,
          'anchor_date': isoDate(anchorDate), 'active': active,
        };
        if (id == null) {
          await _client.from('recurring_rules').insert({...values, 'workspace_id': workspaceId, 'kind': kind, 'currency': currency, 'created_by': _uid});
        } else {
          await _client.from('recurring_rules').update(values).eq('id', id);
        }
      });

  Future<List<Occurrence>> upcoming(DateTime from, DateTime to) => guard(() async {
        final rows = await _client.rpc('upcoming_occurrences', params: {'p_from': isoDate(from), 'p_to': isoDate(to)}) as List;
        return rows.map((r) => Occurrence.fromJson(r as Map<String, dynamic>)).toList();
      });

  Future<void> resolveOccurrence(String ruleId, DateTime dueOn, String status, {String? transactionId}) => guard(() => _client.rpc(
      'resolve_occurrence',
      params: {'p_rule': ruleId, 'p_due_on': isoDate(dueOn), 'p_status': status, 'p_transaction': transactionId}));

  Future<List<MonthlyReport>> reports() => guard(() async {
        final rows = await _client.from('monthly_reports').select().order('period_start', ascending: false).order('report_version', ascending: false);
        return rows.map(MonthlyReport.fromJson).toList();
      });

  Future<Set<String>> staleReportIds() => guard(() async {
        final rows = await _client.rpc('stale_monthly_reports') as List;
        return rows.map((r) => r['report_id'] as String).toSet();
      });

  Future<void> closeMonth(DateTime month, String currency, {bool replace = false}) => guard(() =>
      _client.rpc('close_month', params: {'p_month': isoDate(month), 'p_currency': currency, 'p_replace': replace}));
}
