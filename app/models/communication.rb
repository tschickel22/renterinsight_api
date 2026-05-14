# == Schema Information
#
# Table name: communications
#
#  id                    :bigint           not null, primary key
#  communicable_type     :string           not null
#  communicable_id       :bigint           not null
#  communication_thread_id :bigint
#  direction             :string           not null (outbound, inbound)
#  channel               :string           not null (email, sms, portal_message)
#  provider              :string           (smtp, gmail_relay, aws_ses, twilio)
#  status                :string           not null (pending, sent, delivered, failed, bounced)
#  subject               :string
#  body                  :text
#  from_address          :string
#  to_address            :string
#  cc_addresses          :text
#  bcc_addresses         :text
#  reply_to              :string
#  portal_visible        :boolean          default(false)
#  sent_at               :datetime
#  delivered_at          :datetime
#  failed_at             :datetime
#  error_message         :text
#  metadata              :jsonb
#  external_id           :string           (provider message ID)
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#
# Indexes
#
#  index_communications_on_communicable               (communicable_type, communicable_id)
#  index_communications_on_communication_thread_id    (communication_thread_id)
#  index_communications_on_channel                    (channel)
#  index_communications_on_status                     (status)
#  index_communications_on_external_id                (external_id)
#  index_communications_on_created_at                 (created_at)
#

class Communication < ApplicationRecord
  include ActivityTrackable

  # SQLite compatibility - only serialize for non-PostgreSQL databases
  serialize :metadata, coder: JSON unless ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'

  # Polymorphic association - can belong to Lead, Account, Quote, etc.
  belongs_to :communicable, polymorphic: true, optional: true
  belongs_to :company, optional: true
  belongs_to :communication_thread, optional: true
  belongs_to :template, class_name: 'CommunicationTemplate', foreign_key: 'template_id', optional: true
  belongs_to :workflow_run, class_name: 'WorkflowRun', optional: true

  has_many :communication_events, dependent: :destroy

  after_create :notify_workflow_of_inbound, if: :should_notify_workflow?
  
  # ActiveStorage attachments
  has_many_attached :attachments
  
  # Validations
  validates :direction, presence: true, inclusion: { in: %w[outbound inbound] }
  validates :channel, presence: true, inclusion: { in: %w[email sms portal_message] }
  validates :status, presence: true, inclusion: { in: %w[pending sent delivered failed bounced] }
  validates :body, presence: true
  
  validate :validate_channel_requirements
  
  # Scopes
  scope :outbound, -> { where(direction: 'outbound') }
  scope :inbound, -> { where(direction: 'inbound') }
  scope :email, -> { where(channel: 'email') }
  scope :sms, -> { where(channel: 'sms') }
  scope :portal_visible, -> { where(portal_visible: true) }
  scope :sent, -> { where(status: 'sent') }
  scope :delivered, -> { where(status: 'delivered') }
  scope :failed, -> { where(status: 'failed') }
  scope :pending, -> { where(status: 'pending') }
  scope :recent, -> { order(created_at: :desc) }
  scope :by_thread, ->(thread_id) { where(communication_thread_id: thread_id) }
  scope :scheduled, -> { where(scheduled_status: 'scheduled') }
  scope :ready_to_send, -> { where(scheduled_status: 'scheduled').where('scheduled_for <= ?', Time.current) }
  scope :upcoming, -> { where(scheduled_status: 'scheduled').where('scheduled_for > ?', Time.current).order(:scheduled_for) }
  
  # Thread management
  before_create :assign_to_thread
  after_create :update_thread_timestamp
  
  # Ensure metadata is stored as JSON-compatible hash (string keys, not symbols)
  before_save :normalize_metadata
  
  # Status transitions
  def mark_as_sent!
    update!(status: 'sent', sent_at: Time.current)
  end
  
  def mark_as_delivered!
    return if delivered_at.present?  # Already marked
    update!(status: 'delivered', delivered_at: Time.current)
    track_event('delivered')
  end
  
  def mark_as_failed!(error)
    update!(
      status: 'failed',
      failed_at: Time.current,
      error_message: error.to_s
    )
  end
  
  def mark_as_bounced!
    update!(status: 'bounced', failed_at: Time.current)
  end
  
  # Email tracking
  def mark_as_opened!(ip_address: nil, user_agent: nil)
    return if read_at.present?  # Already opened
    
    update!(read_at: Time.current)
    track_event('opened', ip_address: ip_address, user_agent: user_agent)
  end
  
  def mark_as_clicked!(url:, ip_address: nil, user_agent: nil)
    track_event('clicked', url: url, ip_address: ip_address, user_agent: user_agent)
  end
  
  # Channel checks
  def email?
    channel == 'email'
  end
  
  def sms?
    channel == 'sms'
  end
  
  def portal_message?
    channel == 'portal_message'
  end
  
  def outbound?
    direction == 'outbound'
  end
  
  def inbound?
    direction == 'inbound'
  end

  # Status query methods
  def sent?
    status == 'sent'
  end

  def delivered?
    status == 'delivered'
  end

  def failed?
    status == 'failed'
  end
  
  # Metadata helpers
  def add_metadata(key, value)
    self.metadata ||= {}
    self.metadata[key.to_s] = value
    save
  end
  
  def get_metadata(key)
    metadata&.dig(key.to_s)
  end
  
  # Tracking
  def track_event(event_type, details = {})
    communication_events.create!(
      event_type: event_type,
      occurred_at: Time.current,
      details: details
    )
  end
  
  def opened?
    communication_events.where(event_type: 'opened').exists?
  end

  def open_count
    communication_events.where(event_type: 'opened').count
  end
  
  def clicked?
    communication_events.where(event_type: 'clicked').exists?
  end
  
  # Scheduling methods
  def scheduled?
    scheduled_status == 'scheduled'
  end
  
  def schedule_for(send_at)
    SchedulingService.schedule(self, send_at: send_at)
  end
  
  def cancel_scheduled
    SchedulingService.cancel(self)
  end
  
  def reschedule_to(new_time)
    SchedulingService.reschedule(self, new_time: new_time)
  end
  
  # Attachment helpers
  def has_attachments?
    attachments.attached?
  end
  
  def attachment_count
    attachments.count
  end
  
  def attach_files(file_list)
    AttachmentService.attach_multiple_to_communication(self, file_list)
  end
  
  # ActivityTrackable overrides
  def activity_display_name
    if channel == 'email'
      subject.presence || 'Email'
    elsif channel == 'sms'
      'SMS Message'
    else
      channel&.titleize || 'Communication'
    end
  end

  def activity_module_name
    'communications'
  end

  def activity_account_id
    communicable&.try(:account_id) || communicable&.try(:converted_account_id)
  end

  # Must be public - ActivityTrackable concern uses try(:company)
  def company
    super || communicable&.try(:company)
  end

  private

  def log_create_activity
    action = case channel
             when 'email' then 'email_sent'
             when 'sms' then 'sms_sent'
             else 'created'
             end

    entity = communicable
    description = case channel
                  when 'email' then "Sent email to #{to_address}: #{subject || 'No subject'}"
                  when 'sms' then "Sent SMS to #{to_address}"
                  else "Communication #{channel} created"
                  end

    log_activity(action: action, description: description)
  rescue => e
    Rails.logger.error("[ActivityTrackable] Failed to log create for Communication: #{e.message}")
  end

  def normalize_metadata
    return if metadata.blank?
    
    # Convert symbol keys to string keys for proper JSON storage
    # This prevents Rails from saving as Ruby hash string: {:key=>value}
    # Instead ensures proper JSON: {"key":"value"}
    if metadata.is_a?(Hash)
      self.metadata = metadata.deep_stringify_keys
    end
  end
  
  def validate_channel_requirements
    case channel
    when 'email'
      errors.add(:subject, "can't be blank for email") if subject.blank?
      errors.add(:to_address, "can't be blank for email") if to_address.blank?
      errors.add(:from_address, "can't be blank for email") if from_address.blank?
    when 'sms'
      errors.add(:to_address, "can't be blank for SMS") if to_address.blank?
      errors.add(:from_address, "can't be blank for SMS") if from_address.blank?
    end
  end
  
  def assign_to_thread
    return if communication_thread_id.present?
    
    # Find or create thread for this communicable entity
    thread = CommunicationThread.find_or_create_for(
      communicable_type: communicable_type,
      communicable_id: communicable_id,
      channel: channel
    )
    
    self.communication_thread_id = thread.id
  end
  
  def update_thread_timestamp
    communication_thread&.touch(:last_message_at)
  end

  def should_notify_workflow?
    direction == 'inbound' && communication_thread_id.present?
  end

  def notify_workflow_of_inbound
    parent = Communication
               .where(communication_thread_id: communication_thread_id, direction: 'outbound')
               .where.not(workflow_run_id: nil)
               .order(created_at: :desc)
               .first
    return unless parent&.workflow_run_id
    WorkflowEngine.handle_inbound_reply(workflow_run_id: parent.workflow_run_id, inbound_communication: self)
  rescue => e
    Rails.logger.error "[Communication#notify_workflow_of_inbound] failed: #{e.message}"
  end

end