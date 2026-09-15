# frozen_string_literal: true

# Stops nurture for someone who no longer needs it: they replied, or they
# converted. Nothing did this before, so a lead who answered the first email
# kept getting "just checking in" for two weeks.
#
# Opt-in per sequence (stop_on_reply / stop_on_conversion) so the sequences
# dealers already run keep behaving the way they do today.
class NurtureAutoStop
  ACTIVE_STATUSES = %w[idle running].freeze

  def self.for_reply(communication)
    return 0 unless communication.direction == 'inbound'

    entity = communication.communicable
    return 0 unless entity

    pause(entity, :stop_on_reply)
  end

  def self.for_conversion(lead)
    pause(lead, :stop_on_conversion)
  end

  def self.pause(entity, flag)
    base = if entity.is_a?(Lead)
             # Older enrollments point at the lead through lead_id, not enrollable.
             NurtureEnrollment.for_lead(entity.id)
           else
             NurtureEnrollment.for_entity(entity.class.name, entity.id)
           end

    ids = base.where(status: ACTIVE_STATUSES)
              .where(company_id: entity.company_id)
              .joins(:nurture_sequence)
              .where(nurture_sequences: { flag => true })
              .pluck(:id)
    return 0 if ids.empty?

    NurtureEnrollment.where(id: ids).update_all(status: 'paused', updated_at: Time.current)
  end
  private_class_method :pause
end
