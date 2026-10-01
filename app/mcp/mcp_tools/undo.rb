# frozen_string_literal: true

module McpTools
  # Reverses what an AI app did through the MCP connector, one McpChange at a
  # time. Conservative on purpose: undo restores a value only if it is still
  # the value the AI set, so it never overwrites something a person changed
  # since, and it says why when it skips.
  #
  #   status, owner, stage changes  restored to the value before
  #   notes the AI added            deleted
  #   tasks and service tickets     cancelled, not deleted, so history stays
  #   leads the AI created          deleted only if nobody has touched them
  #   deals moved to won or lost    not undone: that also posts accounting
  #                                 and marks the home sold, which a stage
  #                                 change alone would leave half reversed
  #   draft workflows it created    deleted while still a draft as the AI left it
  #   edits to a draft workflow     restored while still a draft
  #   draft campaigns it created    archived while still a draft
  #   nurture enrollments           paused; anything already sent stays sent
  #   sequences it paused to make   left paused: resuming would send the next
  #   room for a new one            step at once, so a person decides
  module Undo
    LEAD_FIELDS = %w[first_name last_name email phone status owner_id].freeze
    WORKFLOW_FIELDS = %w[name description entity_type trigger conditions steps halt_on_reply].freeze
    UNDO_NOTE = 'Undo of an AI connector change'

    Result = Struct.new(:undone, :message, keyword_init: true) do
      def undone?
        undone
      end
    end

    module_function

    def lead_snapshot(lead)
      lead.attributes.slice(*LEAD_FIELDS)
    end

    def workflow_snapshot(rule)
      rule.attributes.slice(*WORKFLOW_FIELDS).merge('status' => rule.status)
    end

    # Compares stored JSON with live values: jsonb can come back with keys in
    # another order, and numbers as strings, neither of which is a change.
    def same_value?(a, b)
      canonical(a) == canonical(b)
    end

    def canonical(value)
      case value
      when Hash then value.to_h { |k, v| [k.to_s, canonical(v)] }.sort.to_h
      when Array then value.map { |v| canonical(v) }
      when nil then ''
      else value.to_s
      end
    end

    def undo!(change, by:)
      return skipped('Already undone.') if change.undone_at

      record = change.record
      return skipped('The record no longer exists.') unless record
      return skipped('That record belongs to another company.') unless same_company?(record, change)

      result = Current.set(user: by, original_user: by, company_id: change.company_id) do
        change.action == 'created' ? undo_created(change, record) : undo_updated(change, record)
      end
      if result.undone?
        change.update!(undone_at: Time.current, undone_by_user_id: by.id, undo_note: result.message)
      else
        change.update_columns(undo_note: result.message)
      end
      result
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.error("[McpTools::Undo] change #{change.id}: #{e.class}: #{e.message}")
      skipped('Could not be undone automatically. Reverse it by hand on the record.').tap do |r|
        change.update_columns(undo_note: r.message)
      end
    end

    def describe(change)
      label = { 'Lead' => 'lead', 'Deal' => 'deal', 'Note' => 'note', 'Task' => 'task',
                'ServiceTicket' => 'service ticket', 'WorkflowRule' => 'draft workflow', 'Campaign' => 'draft campaign',
                'NurtureEnrollment' => 'nurture enrollment' }[change.record_type] || change.record_type.downcase
      return "Edited #{label} #{change.record_id}" if change.record_type == 'WorkflowRule' && change.action == 'updated'
      if change.action == 'created'
        "Created #{label} #{change.record_id}"
      else
        fields = change.after.keys.reject { |k| k == 'actual_close_date' }
        "Changed #{fields.map { |f| f.tr('_', ' ').sub(/ id\z/, '') }.join(', ')} on #{label} #{change.record_id}: " +
          fields.map { |f| "#{change.before[f].inspect} to #{change.after[f].inspect}" }.join(', ')
      end
    end

    # --- created records ---------------------------------------------------

    def undo_created(change, record)
      case record
      when Note
        return skipped('The note was edited since.') unless record.content == change.after['content']

        record.destroy!
        done('Note deleted.')
      when Task
        return skipped('The task was already worked on.') unless record.status.to_s == change.after['status'].to_s

        record.update!(status: 'cancelled')
        done('Task cancelled.')
      when ServiceTicket
        return skipped('The ticket was already worked on.') unless record.status.to_s == change.after['status'].to_s

        record.update!(status: 'cancelled')
        done('Service ticket cancelled.')
      when WorkflowRule
        unless record.status == 'draft' && same_value?(workflow_snapshot(record), change.after)
          return skipped('The workflow was activated or edited since. Archive it in DealerTide if it should go.')
        end

        record.destroy!
        done('Draft workflow deleted.')
      when Campaign
        return skipped('The campaign has been started since. Pause or archive it in DealerTide.') unless record.status == 'draft'

        record.update!(is_deleted: true, status: 'archived')
        done('Draft campaign archived.')
      when NurtureEnrollment
        return skipped('That enrollment had already stopped.') unless %w[running idle].include?(record.status)

        record.update!(status: 'paused')
        done('Enrollment paused. Messages already sent cannot be recalled.')
      when Lead
        if record.is_converted || lead_snapshot(record).transform_values(&:to_s) != change.after.transform_values(&:to_s)
          return skipped('Someone has worked this lead since it was created. Remove it by hand if it should go.')
        end

        record.destroy!
        done('Lead deleted.')
      else
        skipped('This kind of record cannot be undone automatically.')
      end
    end

    # --- updated records ---------------------------------------------------

    def undo_updated(change, record)
      if record.is_a?(NurtureEnrollment)
        return skipped('Left paused: resuming would send the next step straight away. Resume it on the record ' \
                       'in DealerTide if it should continue.')
      end

      fields = change.after.keys - ['actual_close_date']
      moved = fields.find { |f| !same_value?(record.public_send(f), change.after[f]) }
      if moved
        return skipped("Changed again since: #{moved.tr('_', ' ').sub(/ id\z/, '')} is now " \
                       "#{record.public_send(moved).inspect}. Left as it is.")
      end

      case record
      when Lead
        record.skip_notifications = true # moving it back is not news to anyone
        record.update!(change.before.slice(*fields))
        done("Lead #{fields.join(', ').tr('_', ' ').sub(' id', '')} restored.")
      when WorkflowRule
        record.update!(change.before.slice(*(fields - ['status'])))
        done('Draft workflow restored to how it was before the edit.')
      when Deal
        company = change.company
        if (company.won_stage_keys + company.lost_stage_keys).include?(change.after['stage'].to_s)
          return skipped('Moving a deal to won or lost also updates accounting and inventory. ' \
                         'Move it back by hand on the deal so those are reversed too.')
        end

        Deal.transaction do
          record.update!(stage: change.before['stage'])
          record.update_column(:actual_close_date, change.before['actual_close_date'])
          record.deal_stage_histories.create!(stage: change.before['stage'], previous_stage: change.after['stage'],
                                              changed_by_id: Current.user&.id, notes: UNDO_NOTE)
        end
        done("Deal stage restored to #{change.before['stage']}.")
      else
        skipped('This kind of record cannot be undone automatically.')
      end
    end

    def same_company?(record, change)
      return true unless record.respond_to?(:company_id)

      record.company_id == change.company_id
    end

    def done(message)
      Result.new(undone: true, message: message)
    end

    def skipped(message)
      Result.new(undone: false, message: message)
    end
  end
end
