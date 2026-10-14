# frozen_string_literal: true

# An appointment's calendar invite follows it: sent when it is made, re-sent
# (same UID, next SEQUENCE) when its time, place, title or assignee changes,
# and cancelled when it is cancelled or deleted. A rep taken off it gets a
# cancel for their copy. See Appointments::CalendarInvite.
module SendsAppointmentInvites
  extend ActiveSupport::Concern

  included do
    # Separate names: Rails keeps only the last commit callback per method name.
    after_create_commit :send_invite_on_create
    after_update_commit :send_invite_on_change
    before_destroy :cancel_invite_before_destroy
  end

  private

  def appointment_invitable?
    activity_type == 'meeting' && start_time.present?
  end

  def send_invite_on_create
    return unless appointment_invitable?

    bump_invite_sequence!(0)
    AppointmentInviteJob.perform_later(self.class.name, id, 'REQUEST')
  end

  def send_invite_on_change
    return unless appointment_invitable?

    changed = (saved_changes.keys & Appointments::CalendarInvite::FIELDS)
    return if changed.empty?

    cancelling = saved_change_to_status? && status == 'cancelled'
    return if !cancelling && status != 'pending'

    bump_invite_sequence!
    AppointmentInviteJob.perform_later(self.class.name, id, cancelling ? 'CANCEL' : 'REQUEST')
    cancel_for_former_rep unless cancelling
  end

  # A rep taken off the appointment has it removed from their calendar. The
  # creator stood in as the rep when nobody was assigned.
  def cancel_for_former_rep
    return unless saved_change_to_assigned_to_id?

    former_id = assigned_to_id_before_last_save || user_id
    return if former_id.nil? || former_id == (assigned_to_id || user_id)

    AppointmentInviteJob.perform_later(self.class.name, id, 'CANCEL', former_id)
  end

  # The record is gone by the time a job runs, so this one sends now.
  def cancel_invite_before_destroy
    return unless appointment_invitable? && status == 'pending'

    bump_invite_sequence!
    AppointmentInviteJob.perform_now(self.class.name, id, 'CANCEL')
  rescue StandardError => e
    Rails.logger.warn("[SendsAppointmentInvites] cancel #{self.class.name} #{id}: #{e.message}")
  end

  def bump_invite_sequence!(value = nil)
    notices = customer_notices.to_h
    invite = notices['invite'].to_h
    invite['sequence'] = value.nil? ? invite['sequence'].to_i + 1 : value
    update_column(:customer_notices, notices.merge('invite' => invite))
  end
end
