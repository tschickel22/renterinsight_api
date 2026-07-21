# frozen_string_literal: true

# Backfills sensible default colors on the 17 built-in lead_statuses that
# were seeded with color=NULL. Without this, the badge on the lead page
# used the FE's hardcoded Tailwind palette (blue for New, green for
# Qualified, etc.) while the Lead Statuses tab showed an empty swatch —
# so admins couldn't reason about "what color does this status have?".
#
# Colors are picked to match the existing FE getStatusColor visual palette
# so live badges don't change appearance for tenants that hadn't customized
# their statuses. Only touches rows where color IS NULL — any dealer who
# already picked a custom color keeps it.
class BackfillLeadStatusColors < ActiveRecord::Migration[8.0]
  BUILT_IN_COLORS = {
    'new'                   => '#3b82f6', # blue-500
    'not_contacted'         => '#64748b', # slate-500
    'attempted_to_contact'  => '#f59e0b', # amber-500
    'contact_in_future'     => '#0ea5e9', # sky-500
    'contacted'             => '#eab308', # yellow-500
    'engaged'               => '#6366f1', # indigo-500
    'pre_qualified'         => '#14b8a6', # teal-500
    'qualified'             => '#22c55e', # green-500
    'showing_scheduled'     => '#06b6d4', # cyan-500
    'proposal'              => '#a855f7', # purple-500
    'negotiation'           => '#f97316', # orange-500
    'application_submitted' => '#8b5cf6', # violet-500
    'closed_won'            => '#10b981', # emerald-500
    'closed_lost'           => '#ef4444', # red-500
    'lost_lead'             => '#ec4899', # pink-500
    'not_qualified'         => '#94a3b8', # slate-400
    'junk_lead'             => '#78716c', # stone-500
  }.freeze

  def up
    BUILT_IN_COLORS.each do |key, hex|
      # Only touch rows whose color is still NULL so we don't stomp custom
      # colors admins may have picked since the initial seed.
      LeadStatus.where(key: key, color: nil).update_all(color: hex)
    end
  end

  def down
    LeadStatus.where(key: BUILT_IN_COLORS.keys, color: BUILT_IN_COLORS.values).update_all(color: nil)
  end
end
