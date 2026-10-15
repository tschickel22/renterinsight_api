# frozen_string_literal: true

# An activity (lead, contact, account or deal) given to someone other than the
# person creating it tells them, on create and on reassignment: "Sam set an
# appointment with Pat Smith for you, Tue Oct 14 at 3:00 PM". The creator is
# the default assignee and is never told about their own.
module NotifiesActivityAssignee
  extend ActiveSupport::Concern

  PARENT_PATHS = { 'lead' => '/crm/leads', 'contact' => '/contacts', 'account' => '/accounts', 'deal' => '/deals' }.freeze

  included do
    # Two names on purpose: Rails keeps only the last commit callback
    # registered for one method name, which silently dropped the create one.
    after_create_commit :notify_assignee_on_create
    after_update_commit :notify_assignee_on_reassign, if: :saved_change_to_assigned_to_id?
  end

  private

  def notify_assignee_on_create = notify_new_assignee
  def notify_assignee_on_reassign = notify_new_assignee

  def notify_new_assignee
    assignee = assigned_to
    actor = Current.user || user
    return unless assignee.is_a?(User) && assignee.id != actor&.id

    appointment = activity_type == 'meeting'
    NotificationService.create(
      recipient: assignee,
      notification_type: appointment ? :appointment_assigned : :task_assigned,
      notifiable: self,
      actor: actor,
      message: assignee_message(actor, appointment),
      deliver_now: true,
      action_url: assignee_parent_path,
      action_text: appointment ? 'Open the appointment' : 'Open it'
    )
  rescue StandardError => e
    Rails.logger.warn("[NotifiesActivityAssignee] #{self.class.name} #{id}: #{e.message}")
  end

  def assignee_parent
    PARENT_PATHS.each_key { |name| return [name, public_send(name)] if respond_to?(name) && public_send(name) }
    [nil, nil]
  end

  def assignee_parent_path
    name, record = assignee_parent
    record && "#{PARENT_PATHS[name]}/#{record.id}?tab=activities"
  end

  def assignee_message(actor, appointment)
    _, record = assignee_parent
    who = record && (record.try(:full_name).presence || record.try(:name).presence)
    by = actor&.try(:full_name).presence || actor&.try(:name).presence || 'Someone'
    what = appointment ? 'set an appointment' : "assigned you a #{activity_type.to_s.humanize.downcase}"
    text = appointment ? "#{by} #{what}#{" with #{who}" if who} for you" : "#{by} #{what}#{" for #{who}" if who}"
    when_at = appointment ? start_time : (try(:due_date) || try(:reminder_time))
    zone = record.try(:company)&.time_zone.presence || 'UTC'
    text += ", #{when_at.in_time_zone(zone).strftime('%a %b %-d at %-l:%M %p')}" if when_at
    "#{text}: #{subject}"
  end
end
