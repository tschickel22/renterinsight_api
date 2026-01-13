# DEPRECATED: Commission Rules System

## Status: DEPRECATED - DO NOT USE

This commission rules system was built as an initial prototype but **does not meet production requirements**.

## Why Deprecated?

1. **Not connected to deal economics** - Cannot calculate actual commission on deals
2. **No payment tracking** - No way to track what's owed to salespeople
3. **Wrong abstraction** - Dealers need components (% of gross, bonuses) not generic rules
4. **Data persistence issues** - Product type and timeframe fields don't save correctly

## Replacement

See Phase 0 implementation:
- `commission_components` table - What to pay on (% of gross, flat per unit, bonuses)
- `commission_payments` table - What's owed to whom
- Deal economics calculations - Front/back gross calculations

## Files in Old System

- `app/models/commission_rule.rb`
- `app/models/commission.rb`
- `app/models/commission_audit_entry.rb`
- `app/controllers/api/v1/commission_rules_controller.rb`
- Migrations: `db/migrate/20260102180200_create_commission_rules.rb` (and related)

## Date Deprecated

January 2, 2026

## What to Do

**Keep these files for reference** but do not build on them. Phase 0 starts fresh with proper deal economics integration.
