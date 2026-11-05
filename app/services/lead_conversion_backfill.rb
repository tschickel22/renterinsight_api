# frozen_string_literal: true

# One time, for leads converted before conversion carried everything: copy to each
# account the tags, notes and activities it never got, and retire the lead's open
# activities whose copy is on the account (they were reminding reps twice).
# Safe to run twice: everything already on the account is matched and skipped.
# Dry run unless apply: true. Run: bin/rails leads:backfill_conversions (APPLY=1 to write).
class LeadConversionBackfill
  def self.call(apply: false, scope: Lead.where(is_converted: true).where.not(converted_account_id: nil))
    new(apply).run(scope)
  end

  def initialize(apply)
    @apply = apply
    @totals = %i[leads accounts_missing activities_copied open_activities_retired tags_copied notes_copied open_reminders_moved].index_with(0)
  end

  def run(scope)
    scope.find_each do |lead|
      account = Account.find_by(id: lead.converted_account_id, company_id: lead.company_id)
      next @totals[:accounts_missing] += 1 unless account

      @totals[:leads] += 1
      ActiveRecord::Base.transaction { backfill(lead, account) }
    end
    @totals.merge(applied: @apply)
  end

  private

  def backfill(lead, account)
    copied_keys = AccountActivity.where(account_id: account.id).pluck(:activity_type, :created_at).map { |t, c| [t, c.to_i] }.to_set
    lead.lead_activities.find_each do |la|
      if copied_keys.include?([la.activity_type, la.created_at.to_i])
        if LeadConversionCarry::OPEN_ACTIVITY.include?(la.status)
          @totals[:open_activities_retired] += 1
          LeadConversionCarry.retire_open_activity(la) if @apply
        end
        next
      end
      @totals[:activities_copied] += 1
      LeadConversionCarry.copy_activity(la, account: account, lead: lead) if @apply
    end

    have_tags = TagAssignment.where(entity_type: 'Account', entity_id: account.id).pluck(:tag_id)
    missing_tags = lead.tags.pluck(:id) - have_tags
    @totals[:tags_copied] += missing_tags.size

    have_notes = Note.where(entity_type: %w[account Account], entity_id: account.id.to_s).pluck(:content, :created_at).map { |c, t| [c, t.to_i] }.to_set
    missing_notes = Note.where(entity_type: %w[lead Lead], entity_id: lead.id.to_s).reject { |n| have_notes.include?([n.content, n.created_at.to_i]) }
    @totals[:notes_copied] += missing_notes.size

    @totals[:open_reminders_moved] += lead.reminders.where(is_completed: [false, nil]).count + lead.lead_tasks.where(done: [false, nil]).count
    return unless @apply

    LeadConversionCarry.new(lead, account, false).send(:carry_tags)
    missing_notes.each do |note|
      Note.create!(entity_type: 'account', entity_id: account.id.to_s, content: note.content, user_id: note.user_id,
                   created_by_name: note.created_by_name, category: note.category, author_type: note.author_type,
                   created_at: note.created_at, updated_at: note.updated_at)
    end
    carry = LeadConversionCarry.new(lead, account, false)
    carry.send(:carry_reminders)
    carry.send(:carry_tasks)
  end
end
