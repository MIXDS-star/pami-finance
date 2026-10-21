import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/finance/expense_draft.dart';
import '../models.dart';
import 'guard.dart';

/// Official aggregations computed by the server (docs/FORMULAS.md).
class AnalyticsRepository {
  AnalyticsRepository(this._client);
  final SupabaseClient _client;

  Future<PeriodSummary> summary(DateTime from, DateTime to, String currency) => guard(() async => PeriodSummary.fromJson(
      Map<String, dynamic>.from(await _client.rpc('my_period_summary',
          params: {'p_from': isoDate(from), 'p_to': isoDate(to), 'p_currency': currency}) as Map)));

  Future<List<CategorySpend>> byCategory(DateTime from, DateTime to, String currency, {String? workspaceId}) => guard(() async {
        final rows = await _client.rpc('spending_by_category',
            params: {'p_from': isoDate(from), 'p_to': isoDate(to), 'p_currency': currency, 'p_workspace': workspaceId}) as List;
        return rows.map((r) => CategorySpend.fromJson(r as Map<String, dynamic>)).toList();
      });

  Future<List<TrendPoint>> trend(int months, String currency) => guard(() async {
        final rows = await _client.rpc('monthly_trend', params: {'p_months': months, 'p_currency': currency}) as List;
        return rows.map((r) => TrendPoint.fromJson(r as Map<String, dynamic>)).toList();
      });

  Future<List<MerchantSpend>> topMerchants(DateTime from, DateTime to, String currency) => guard(() async {
        final rows = await _client.rpc('top_merchants',
            params: {'p_from': isoDate(from), 'p_to': isoDate(to), 'p_currency': currency, 'p_limit': 5}) as List;
        return rows.map((r) => MerchantSpend.fromJson(r as Map<String, dynamic>)).toList();
      });
}
