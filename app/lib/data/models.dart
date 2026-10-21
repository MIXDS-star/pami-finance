/// Typed views over the database rows the app reads. Writes never go through
/// these: ledger writes use ExpenseDraft -> public.save_transaction.
library;

import 'package:flutter/material.dart';

import '../core/money/money.dart';

int _int(Object? v) => (v as num?)?.toInt() ?? 0;
int? _intN(Object? v) => (v as num?)?.toInt();
DateTime? _dt(Object? v) => v == null ? null : DateTime.parse(v as String).toLocal();
DateTime _date(Object? v) {
  final p = (v as String).split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2]);
}

enum WorkspaceKind { personal, household, couple, friends, trip, other }

extension WorkspaceKindX on WorkspaceKind {
  String get label => switch (this) {
        WorkspaceKind.personal => 'Personal',
        WorkspaceKind.household => 'Hogar',
        WorkspaceKind.couple => 'Pareja',
        WorkspaceKind.friends => 'Amigos',
        WorkspaceKind.trip => 'Viaje o evento',
        WorkspaceKind.other => 'Otro',
      };
  IconData get icon => switch (this) {
        WorkspaceKind.personal => Icons.person_outline,
        WorkspaceKind.household => Icons.home_outlined,
        WorkspaceKind.couple => Icons.favorite_border,
        WorkspaceKind.friends => Icons.groups_outlined,
        WorkspaceKind.trip => Icons.luggage_outlined,
        WorkspaceKind.other => Icons.workspaces_outline,
      };
}

enum MemberRole { owner, admin, member, viewer }

extension MemberRoleX on MemberRole {
  String get label => switch (this) {
        MemberRole.owner => 'Propietario',
        MemberRole.admin => 'Administrador',
        MemberRole.member => 'Miembro',
        MemberRole.viewer => 'Lector',
      };
  String get description => switch (this) {
        MemberRole.owner => 'Control total, incluida la propiedad del espacio.',
        MemberRole.admin => 'Invita, gestiona miembros y edita cualquier movimiento.',
        MemberRole.member => 'Registra y edita gastos compartidos.',
        MemberRole.viewer => 'Solo puede consultar.',
      };
  bool get canWrite => this != MemberRole.viewer;
  bool get canAdmin => this == MemberRole.owner || this == MemberRole.admin;
}

class Profile {
  const Profile({required this.id, required this.displayName, this.deleted = false});
  factory Profile.fromJson(Map<String, dynamic> j) =>
      Profile(id: j['id'] as String, displayName: j['display_name'] as String, deleted: j['deleted_at'] != null);
  final String id;
  final String displayName;
  final bool deleted;

  String get initials {
    final parts = displayName.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    return (parts.first[0] + (parts.length > 1 ? parts.last[0] : '')).toUpperCase();
  }
}

class Preferences {
  Preferences.fromJson(Map<String, dynamic> j)
      : countryCode = j['country_code'] as String,
        defaultCurrency = j['default_currency'] as String,
        timezone = j['timezone'] as String,
        theme = j['theme'] as String,
        incomeFrequency = j['income_frequency'] as String?,
        incomeDay = _intN(j['income_day']),
        financialGoals = ((j['financial_goals'] as List?) ?? const []).cast<String>(),
        showAmountsInNotifications = j['show_amounts_in_notifications'] as bool? ?? false,
        notificationSettings = Map<String, dynamic>.from(j['notification_settings'] as Map? ?? const {}),
        onboardingCompleted = j['onboarding_completed_at'] != null;

  final String countryCode;
  final String defaultCurrency;
  final String timezone;
  final String theme;
  final String? incomeFrequency;
  final int? incomeDay;
  final List<String> financialGoals;
  final bool showAmountsInNotifications;
  final Map<String, dynamic> notificationSettings;
  final bool onboardingCompleted;

  ThemeMode get themeMode => switch (theme) { 'light' => ThemeMode.light, 'dark' => ThemeMode.dark, _ => ThemeMode.system };
}

class Workspace {
  const Workspace({
    required this.id,
    required this.kind,
    required this.name,
    required this.baseCurrency,
    required this.defaultSplit,
    required this.version,
    required this.createdBy,
    this.archived = false,
    this.myRole,
  });

  factory Workspace.fromJson(Map<String, dynamic> j, {MemberRole? myRole}) => Workspace(
        id: j['id'] as String,
        kind: WorkspaceKind.values.byName(j['kind'] as String),
        name: j['name'] as String,
        baseCurrency: Currency.of(j['base_currency'] as String),
        defaultSplit: Map<String, dynamic>.from(j['default_split'] as Map? ?? const {'method': 'equal'}),
        version: _int(j['version']),
        createdBy: j['created_by'] as String,
        archived: j['archived_at'] != null,
        myRole: myRole,
      );

  final String id;
  final WorkspaceKind kind;
  final String name;
  final Currency baseCurrency;
  final Map<String, dynamic> defaultSplit;
  final int version;
  final String createdBy;
  final bool archived;
  final MemberRole? myRole;

  bool get isPersonal => kind == WorkspaceKind.personal;
  bool get canWrite => !archived && (myRole?.canWrite ?? false);
  bool get canAdmin => myRole?.canAdmin ?? false;
}

class Member {
  const Member({required this.userId, required this.role, required this.active, required this.displayName, this.joinedAt});
  final String userId;
  final MemberRole role;
  final bool active;
  final String displayName;
  final DateTime? joinedAt;

  String get initials => Profile(id: userId, displayName: displayName).initials;
}

class Category {
  const Category({
    required this.id,
    required this.kind,
    required this.name,
    required this.icon,
    required this.color,
    this.workspaceId,
    this.systemKey,
    this.bucket,
  });

  factory Category.fromJson(Map<String, dynamic> j) => Category(
        id: j['id'] as String,
        kind: j['kind'] as String,
        name: j['name'] as String,
        icon: j['icon'] as String,
        color: Color(int.parse((j['color'] as String).substring(1), radix: 16) | 0xFF000000),
        workspaceId: j['workspace_id'] as String?,
        systemKey: j['system_key'] as String?,
        bucket: j['budget_bucket'] as String?,
      );

  final String id;
  final String kind;
  final String name;
  final String icon;
  final Color color;
  final String? workspaceId;
  final String? systemKey;
  final String? bucket;

  IconData get iconData => categoryIcon(icon);
}

IconData categoryIcon(String name) => switch (name) {
      'shopping_basket' => Icons.shopping_basket_outlined,
      'restaurant' => Icons.restaurant_outlined,
      'directions_bus' => Icons.directions_bus_outlined,
      'home' => Icons.home_outlined,
      'bolt' => Icons.bolt_outlined,
      'favorite' => Icons.favorite_border,
      'school' => Icons.school_outlined,
      'movie' => Icons.movie_outlined,
      'shopping_bag' => Icons.shopping_bag_outlined,
      'subscriptions' => Icons.subscriptions_outlined,
      'flight' => Icons.flight_outlined,
      'pets' => Icons.pets_outlined,
      'spa' => Icons.spa_outlined,
      'redeem' => Icons.redeem_outlined,
      'credit_card' => Icons.credit_card_outlined,
      'account_balance' => Icons.account_balance_outlined,
      'work' => Icons.work_outline,
      'trending_up' => Icons.trending_up,
      'star' => Icons.star_outline,
      _ => Icons.category_outlined,
    };

enum AccountType { cash, bank, creditCard, wallet, other }

extension AccountTypeX on AccountType {
  String get wire => switch (this) { AccountType.creditCard => 'credit_card', _ => name };
  String get label => switch (this) {
        AccountType.cash => 'Efectivo',
        AccountType.bank => 'Cuenta bancaria',
        AccountType.creditCard => 'Tarjeta de crédito',
        AccountType.wallet => 'Billetera digital',
        AccountType.other => 'Otra',
      };
  IconData get icon => switch (this) {
        AccountType.cash => Icons.payments_outlined,
        AccountType.bank => Icons.account_balance_outlined,
        AccountType.creditCard => Icons.credit_card,
        AccountType.wallet => Icons.account_balance_wallet_outlined,
        AccountType.other => Icons.savings_outlined,
      };
  static AccountType parse(String s) => s == 'credit_card' ? AccountType.creditCard : AccountType.values.byName(s);
}

class Account {
  const Account({required this.id, required this.name, required this.type, required this.currency,
      required this.openingBalanceMinor, required this.version, this.creditLimitMinor, this.archived = false});
  factory Account.fromJson(Map<String, dynamic> j) => Account(
        id: j['id'] as String,
        name: j['name'] as String,
        type: AccountTypeX.parse(j['type'] as String),
        currency: Currency.of(j['currency'] as String),
        openingBalanceMinor: _int(j['opening_balance_minor']),
        creditLimitMinor: _intN(j['credit_limit_minor']),
        version: _int(j['version']),
        archived: j['archived_at'] != null,
      );
  final String id;
  final String name;
  final AccountType type;
  final Currency currency;
  final int openingBalanceMinor;
  final int? creditLimitMinor;
  final int version;
  final bool archived;
}

const paymentMethodLabels = {
  'cash': 'Efectivo',
  'debit_card': 'Tarjeta débito',
  'credit_card': 'Tarjeta crédito',
  'bank_transfer': 'Transferencia',
  'digital_wallet': 'Billetera digital',
  'other': 'Otro',
};

class Payment {
  const Payment({required this.payerId, required this.amountMinor, this.accountId, this.method});
  factory Payment.fromJson(Map<String, dynamic> j) => Payment(
      payerId: j['payer_id'] as String, amountMinor: _int(j['amount_minor']),
      accountId: j['account_id'] as String?, method: j['method'] as String?);
  final String payerId;
  final int amountMinor;
  final String? accountId;
  final String? method;
}

class Split {
  const Split(this.userId, this.amountMinor);
  final String userId;
  final int amountMinor;
}

class ReceiptItemRow {
  const ReceiptItemRow({required this.id, required this.position, required this.kind, required this.description,
      required this.lineTotalMinor, required this.quantity, required this.allocationMethod, this.allocationSpec,
      this.rawText, this.unitPriceMinor, this.lineDiscountMinor = 0, this.categoryId, this.confidence, this.allocations = const []});
  factory ReceiptItemRow.fromJson(Map<String, dynamic> j) => ReceiptItemRow(
        id: j['id'] as String,
        position: _int(j['position']),
        kind: j['kind'] as String,
        description: j['description'] as String,
        rawText: j['raw_text'] as String?,
        quantity: (j['quantity'] as num?)?.toString() ?? '1',
        unitPriceMinor: _intN(j['unit_price_minor']),
        lineDiscountMinor: _int(j['line_discount_minor']),
        lineTotalMinor: _int(j['line_total_minor']),
        categoryId: j['category_id'] as String?,
        confidence: (j['confidence'] as num?)?.toDouble(),
        allocationMethod: j['allocation_method'] as String,
        allocationSpec: (j['allocation_spec'] as Map?)?.cast<String, dynamic>(),
        allocations: ((j['receipt_item_allocations'] as List?) ?? const [])
            .map((a) => Split(a['user_id'] as String, _int(a['amount_minor'])))
            .toList(),
      );
  final String id;
  final int position;
  final String kind;
  final String description;
  final String? rawText;
  final String quantity;
  final int? unitPriceMinor;
  final int lineDiscountMinor;
  final int lineTotalMinor;
  final String? categoryId;
  final double? confidence;
  final String allocationMethod;
  final Map<String, dynamic>? allocationSpec;
  final List<Split> allocations;
}

class ReceiptRow {
  ReceiptRow.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        storagePath = j['storage_path'] as String?,
        mimeType = j['mime_type'] as String?,
        merchantName = j['merchant_name'] as String?,
        merchantTaxId = j['merchant_tax_id'] as String?,
        invoiceNumber = j['invoice_number'] as String?,
        issuedOn = j['issued_on'] == null ? null : _date(j['issued_on']),
        printedSubtotalMinor = _intN(j['printed_subtotal_minor']),
        printedTotalMinor = _intN(j['printed_total_minor']),
        discountMinor = _int(j['discount_minor']),
        taxMinor = _int(j['tax_minor']),
        taxesIncluded = j['taxes_included'] as bool? ?? true,
        tipMinor = _int(j['tip_minor']),
        otherChargesMinor = _int(j['other_charges_minor']),
        extractionStatus = j['extraction_status'] as String,
        extractionProvider = j['extraction_provider'] as String?,
        extractionConfidence = (j['extraction_confidence'] as num?)?.toDouble(),
        items = (((j['receipt_items'] as List?) ?? const []).map((i) => ReceiptItemRow.fromJson(i as Map<String, dynamic>)).toList())
          ..sort((a, b) => a.position.compareTo(b.position));

  final String id;
  final String? storagePath;
  final String? mimeType;
  final String? merchantName;
  final String? merchantTaxId;
  final String? invoiceNumber;
  final DateTime? issuedOn;
  final int? printedSubtotalMinor;
  final int? printedTotalMinor;
  final int discountMinor;
  final int taxMinor;
  final bool taxesIncluded;
  final int tipMinor;
  final int otherChargesMinor;
  final String extractionStatus;
  final String? extractionProvider;
  final double? extractionConfidence;
  final List<ReceiptItemRow> items;
}

class Transaction {
  Transaction.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        workspaceId = j['workspace_id'] as String,
        kind = j['kind'] as String,
        description = j['description'] as String,
        merchant = j['merchant'] as String?,
        occurredOn = _date(j['occurred_on']),
        currency = Currency.of(j['currency'] as String),
        totalMinor = _int(j['total_minor']),
        categoryId = j['category_id'] as String?,
        splitMethod = j['split_method'] as String?,
        splitSpec = (j['split_spec'] as Map?)?.cast<String, dynamic>(),
        notes = j['notes'] as String?,
        source = j['source'] as String,
        accountId = j['account_id'] as String?,
        toAccountId = j['to_account_id'] as String?,
        createdBy = j['created_by'] as String,
        createdAt = _dt(j['created_at'])!,
        updatedAt = _dt(j['updated_at'])!,
        deleted = j['deleted_at'] != null,
        version = _int(j['version']),
        payments = ((j['transaction_payments'] as List?) ?? const []).map((p) => Payment.fromJson(p as Map<String, dynamic>)).toList(),
        splits = ((j['transaction_splits'] as List?) ?? const [])
            .map((s) => Split(s['user_id'] as String, _int(s['amount_minor'])))
            .toList(),
        receipt = _receipt(j['receipts']);

  static ReceiptRow? _receipt(Object? v) {
    if (v is Map<String, dynamic>) return ReceiptRow.fromJson(v);
    if (v is List && v.isNotEmpty) return ReceiptRow.fromJson(v.first as Map<String, dynamic>);
    return null;
  }

  final String id;
  final String workspaceId;
  final String kind;
  final String description;
  final String? merchant;
  final DateTime occurredOn;
  final Currency currency;
  final int totalMinor;
  final String? categoryId;
  final String? splitMethod;
  final Map<String, dynamic>? splitSpec;
  final String? notes;
  final String source;
  final String? accountId;
  final String? toAccountId;
  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool deleted;
  final int version;
  final List<Payment> payments;
  final List<Split> splits;
  final ReceiptRow? receipt;

  bool get isExpense => kind == 'expense';
  bool get isIncome => kind == 'income';
  bool get isTransfer => kind == 'transfer';

  int shareOf(String userId) => splits.where((s) => s.userId == userId).fold(0, (a, s) => a + s.amountMinor);
  int paidBy(String userId) => payments.where((p) => p.payerId == userId).fold(0, (a, p) => a + p.amountMinor);
}

class Settlement {
  Settlement.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        workspaceId = j['workspace_id'] as String,
        fromUserId = j['from_user_id'] as String,
        toUserId = j['to_user_id'] as String,
        amountMinor = _int(j['amount_minor']),
        currency = Currency.of(j['currency'] as String),
        occurredOn = _date(j['occurred_on']),
        method = j['method'] as String?,
        note = j['note'] as String?,
        createdBy = j['created_by'] as String,
        version = _int(j['version']);
  final String id;
  final String workspaceId;
  final String fromUserId;
  final String toUserId;
  final int amountMinor;
  final Currency currency;
  final DateTime occurredOn;
  final String? method;
  final String? note;
  final String createdBy;
  final int version;
}

class Invitation {
  Invitation.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        email = j['email'] as String?,
        role = MemberRole.values.byName(j['role'] as String),
        createdAt = _dt(j['created_at'])!,
        expiresAt = _dt(j['expires_at'])!,
        status = j['accepted_at'] != null
            ? 'accepted'
            : j['declined_at'] != null
                ? 'declined'
                : j['revoked_at'] != null
                    ? 'revoked'
                    : (_dt(j['expires_at'])!.isBefore(DateTime.now()) ? 'expired' : 'pending');
  final String id;
  final String? email;
  final MemberRole role;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String status;
}

class AuditEvent {
  AuditEvent.fromJson(Map<String, dynamic> j)
      : id = _int(j['id']),
        actorId = j['actor_id'] as String?,
        action = j['action'] as String,
        changes = Map<String, dynamic>.from(j['changes'] as Map? ?? const {}),
        occurredAt = _dt(j['occurred_at'])!;
  final int id;
  final String? actorId;
  final String action;
  final Map<String, dynamic> changes;
  final DateTime occurredAt;
}

class PeriodSummary {
  PeriodSummary.fromJson(Map<String, dynamic> j)
      : incomeMinor = _int(j['income_minor']),
        expenseAssignedMinor = _int(j['expense_assigned_minor']),
        expensePersonalMinor = _int(j['expense_personal_minor']),
        expenseSharedMinor = _int(j['expense_shared_assigned_minor']),
        paidMinor = _int(j['paid_minor']),
        netSavingsMinor = _int(j['net_savings_minor']),
        savingsRateBp = _intN(j['savings_rate_bp']),
        expenseCount = _int((j['counts'] as Map?)?['expenses']),
        incomeCount = _int((j['counts'] as Map?)?['incomes']),
        periodComplete = (j['data_quality'] as Map?)?['period_complete'] as bool? ?? false,
        formulas = Map<String, String>.from(j['formulas'] as Map? ?? const {});
  final int incomeMinor;
  final int expenseAssignedMinor;
  final int expensePersonalMinor;
  final int expenseSharedMinor;
  final int paidMinor;
  final int netSavingsMinor;
  final int? savingsRateBp;
  final int expenseCount;
  final int incomeCount;
  final bool periodComplete;
  final Map<String, String> formulas;
}

class CategorySpend {
  CategorySpend.fromJson(Map<String, dynamic> j)
      : categoryId = j['category_id'] as String?,
        name = j['category_name'] as String,
        color = Color(int.parse((j['color'] as String).substring(1), radix: 16) | 0xFF000000),
        icon = j['icon'] as String,
        amountMinor = _int(j['amount_minor']),
        count = _int(j['tx_count']);
  final String? categoryId;
  final String name;
  final Color color;
  final String icon;
  final int amountMinor;
  final int count;
}

class TrendPoint {
  TrendPoint.fromJson(Map<String, dynamic> j)
      : month = _date(j['month']),
        incomeMinor = _int(j['income_minor']),
        expenseMinor = _int(j['expense_assigned_minor']);
  final DateTime month;
  final int incomeMinor;
  final int expenseMinor;
}

class MerchantSpend {
  MerchantSpend.fromJson(Map<String, dynamic> j)
      : merchant = j['merchant'] as String,
        amountMinor = _int(j['amount_minor']),
        count = _int(j['tx_count']);
  final String merchant;
  final int amountMinor;
  final int count;
}

class Budget {
  Budget.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        workspaceId = j['workspace_id'] as String,
        name = j['name'] as String,
        currency = Currency.of(j['currency'] as String),
        amountMinor = _intN(j['amount_minor']),
        incomeShareBp = _intN(j['income_share_bp']),
        alertThresholdBp = _int(j['alert_threshold_bp']),
        version = _int(j['version']),
        categoryIds = ((j['budget_categories'] as List?) ?? const []).map((c) => c['category_id'] as String).toList();
  final String id;
  final String workspaceId;
  final String name;
  final Currency currency;
  final int? amountMinor;
  final int? incomeShareBp;
  final int alertThresholdBp;
  final int version;
  final List<String> categoryIds;
}

class BudgetStatus {
  BudgetStatus.fromJson(Map<String, dynamic> j)
      : budgetId = j['budget_id'] as String,
        workspaceId = j['workspace_id'] as String,
        name = j['name'] as String,
        currency = Currency.of(j['currency'] as String),
        limitMinor = _int(j['limit_minor']),
        spentMinor = _int(j['spent_minor']),
        availableMinor = _int(j['available_minor']),
        consumedBp = _intN(j['consumed_bp']),
        projectedMinor = _int(j['projected_minor']),
        alert = j['alert'] as bool? ?? false,
        daysElapsed = _int(j['days_elapsed']),
        daysInPeriod = _int(j['days_in_period']),
        categoryIds = ((j['category_ids'] as List?) ?? const []).cast<String>();
  final String budgetId;
  final String workspaceId;
  final String name;
  final Currency currency;
  final int limitMinor;
  final int spentMinor;
  final int availableMinor;
  final int? consumedBp;
  final int projectedMinor;
  final bool alert;
  final int daysElapsed;
  final int daysInPeriod;
  final List<String> categoryIds;
}

class Goal {
  Goal.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        workspaceId = j['workspace_id'] as String,
        kind = j['kind'] as String,
        name = j['name'] as String,
        currency = Currency.of(j['currency'] as String),
        targetMinor = _int(j['target_minor']),
        targetDate = j['target_date'] == null ? null : _date(j['target_date']),
        plannedMonthlyMinor = _intN(j['planned_monthly_minor']),
        priority = _int(j['priority']),
        version = _int(j['version']);
  final String id;
  final String workspaceId;
  final String kind;
  final String name;
  final Currency currency;
  final int targetMinor;
  final DateTime? targetDate;
  final int? plannedMonthlyMinor;
  final int priority;
  final int version;
}

class GoalProgress {
  GoalProgress.fromJson(Map<String, dynamic> j)
      : goalId = j['goal_id'] as String,
        savedMinor = _int(j['saved_minor']),
        remainingMinor = _int(j['remaining_minor']),
        progressBp = _int(j['progress_bp']),
        monthsLeft = _intN(j['months_left']),
        requiredMonthlyMinor = _intN(j['required_monthly_minor']),
        projectedCompletion = j['projected_completion'] == null ? null : _date(j['projected_completion']);
  final String goalId;
  final int savedMinor;
  final int remainingMinor;
  final int progressBp;
  final int? monthsLeft;
  final int? requiredMonthlyMinor;
  final DateTime? projectedCompletion;
}

class Contribution {
  Contribution.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        amountMinor = _int(j['amount_minor']),
        occurredOn = _date(j['occurred_on']),
        note = j['note'] as String?;
  final String id;
  final int amountMinor;
  final DateTime occurredOn;
  final String? note;
}

class RecurringRule {
  RecurringRule.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        workspaceId = j['workspace_id'] as String,
        kind = j['kind'] as String,
        label = j['label'] as String,
        categoryId = j['category_id'] as String?,
        currency = Currency.of(j['currency'] as String),
        expectedMinor = _int(j['expected_minor']),
        frequency = j['frequency'] as String,
        anchorDate = _date(j['anchor_date']),
        active = j['active'] as bool? ?? true;
  final String id;
  final String workspaceId;
  final String kind;
  final String label;
  final String? categoryId;
  final Currency currency;
  final int expectedMinor;
  final String frequency;
  final DateTime anchorDate;
  final bool active;
}

class Occurrence {
  Occurrence.fromJson(Map<String, dynamic> j)
      : ruleId = j['rule_id'] as String,
        workspaceId = j['workspace_id'] as String,
        kind = j['kind'] as String,
        label = j['label'] as String,
        currency = Currency.of(j['currency'] as String),
        dueOn = _date(j['due_on']),
        expectedMinor = _int(j['expected_minor']),
        status = j['status'] as String,
        transactionId = j['transaction_id'] as String?;
  final String ruleId;
  final String workspaceId;
  final String kind;
  final String label;
  final Currency currency;
  final DateTime dueOn;
  final int expectedMinor;
  final String status;
  final String? transactionId;
}

class MonthlyReport {
  MonthlyReport.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        periodStart = _date(j['period_start']),
        currency = Currency.of(j['currency'] as String),
        version = _int(j['report_version']),
        snapshot = Map<String, dynamic>.from(j['snapshot'] as Map),
        dataQuality = Map<String, dynamic>.from(j['data_quality'] as Map? ?? const {}),
        superseded = j['superseded_at'] != null,
        closedAt = _dt(j['closed_at'])!;
  final String id;
  final DateTime periodStart;
  final Currency currency;
  final int version;
  final Map<String, dynamic> snapshot;
  final Map<String, dynamic> dataQuality;
  final bool superseded;
  final DateTime closedAt;
}

class AppNotification {
  AppNotification.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        kind = j['kind'] as String,
        title = j['title'] as String,
        body = j['body'] as String?,
        entityType = j['entity_type'] as String?,
        entityId = j['entity_id'] as String?,
        workspaceId = j['workspace_id'] as String?,
        read = j['read_at'] != null,
        createdAt = _dt(j['created_at'])!;
  final String id;
  final String kind;
  final String title;
  final String? body;
  final String? entityType;
  final String? entityId;
  final String? workspaceId;
  final bool read;
  final DateTime createdAt;
}
