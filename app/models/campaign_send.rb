class CampaignSend < ApplicationRecord
  belongs_to :campaign
  belongs_to :campaign_step
  belongs_to :campaign_enrollment
  belongs_to :communication, optional: true
  has_many :campaign_link_tokens, dependent: :destroy

  # Bounces are always written with update!, so a callback sees every one. Opens,
  # clicks and replies are not (update_all / update_columns), which is why those
  # emit from the record_* methods below and from Campaigns::ReplyHandler.
  after_update_commit :emit_bounce_to_workflows,
                      if: -> { saved_change_to_bounced_at? && attribute_before_last_save(:bounced_at).nil? && bounced_at.present? }

  # Sends that belong to a real (non-test) enrollment. campaign_enrollment_id is NOT NULL,
  # so this subquery exclusion is NULL-safe. Keeps test-send rows out of analytics totals.
  scope :real, -> { where.not(campaign_enrollment_id: CampaignEnrollment.test_sends.select(:id)) }

  # Delivery that actually held. A receiving server can accept a message at SMTP time and
  # reject it moments later, which produces a Delivery event AND then a Bounce event for the
  # same send. Counting delivered_at on its own therefore reported those as both delivered
  # and bounced, overstating the delivery rate by exactly the async-bounce count — on the
  # first SES campaign that was 3 of 52, every one of them a hard bounce.
  scope :delivered, -> { where.not(delivered_at: nil).where(bounced_at: nil) }

  # Bridge open/click tracking (recorded against the Communication / TrackedLink) into the
  # campaign analytics columns the stats rollup and timeseries read. opened_at/clicked_at are
  # stamped once (first event); the *_count columns increment on every event. The first
  # open or click of each send is also handed to the workflow engine.
  def self.record_open_for_communication(communication_id)
    return if communication_id.blank?
    scope = where(communication_id: communication_id)
    first_opens = claim_first(scope, :opened_at)
    scope.update_all('open_count = open_count + 1')
    emit_to_workflows(:opened, first_opens)
  end

  # A click implies an open: the recipient must have opened the email to click a link.
  # Open pixels are frequently blocked by mail clients, so without this a clicked email
  # could show 0 opens. Stamp opened_at if not already set (open_count to at least 1).
  def self.record_click_for_communication(communication_id, url: nil)
    return if communication_id.blank?
    record_click(where(communication_id: communication_id), url: url)
  end

  # The same for a campaign content link (CampaignLinkToken), which knows its send
  # directly instead of through a Communication.
  def self.record_click_for_send(send, url: nil)
    return if send.nil?
    record_click(where(id: send.id), url: url)
  end

  def self.record_click(scope, url:)
    first_opens = claim_first(scope, :opened_at)
    first_clicks = claim_first(scope, :clicked_at)
    scope.update_all('click_count = click_count + 1, open_count = GREATEST(open_count, 1)')
    emit_to_workflows(:opened, first_opens)
    emit_to_workflows(:clicked, first_clicks, url: url)
  end
  private_class_method :record_click

  # Stamps column on each send in scope that lacks it and returns the ids this call
  # stamped. The per-row "column IS NULL" guard is what makes two opens landing at
  # the same moment report the first open once, not twice.
  def self.claim_first(scope, column)
    scope.where(column => nil).pluck(:id).select do |id|
      where(id: id, column => nil).update_all(column => Time.current) == 1
    end
  end
  private_class_method :claim_first

  def self.emit_to_workflows(kind, ids, **extra)
    return if ids.empty?
    includes(:campaign_enrollment).where(id: ids).find_each do |send|
      Campaigns::WorkflowBridge.emit(kind, send: send, **extra)
    end
  end
  private_class_method :emit_to_workflows

  private

  def emit_bounce_to_workflows
    Campaigns::WorkflowBridge.emit(:bounced, send: self, bounce_type: bounce_type)
  end
end
