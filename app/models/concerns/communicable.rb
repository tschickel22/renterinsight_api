# Concern to add communication associations and preferences to models
# Include this in Lead, Account, Quote, and other communicable models
#
# Usage:
#   class Lead < ApplicationRecord
#     include Communicable
#   end

module Communicable
  extend ActiveSupport::Concern
  
  included do
    # Polymorphic associations
    has_many :communications, as: :communicable, dependent: :destroy
    has_many :communication_preferences, as: :recipient, dependent: :destroy
    
    # Scopes for communications
    scope :with_communications, -> { 
      joins(:communications).distinct 
    }
    
    scope :with_recent_communications, ->(days = 30) {
      joins(:communications)
        .where('communications.created_at >= ?', days.days.ago)
        .distinct
    }
  end
  
  # Communication sending helpers
  def send_email(to:, subject:, body:, **options)
    CommunicationService.send_email(
      communicable: self,
      to: to,
      subject: subject,
      body: body,
      **options
    )
  end
  
  def send_sms(to:, body:, **options)
    CommunicationService.send_sms(
      communicable: self,
      to: to,
      body: body,
      **options
    )
  end
  
  def send_portal_message(to:, body:, **options)
    CommunicationService.send_portal_message(
      communicable: self,
      to: to,
      body: body,
      **options
    )
  end
  
  # Communication queries
  def recent_communications(limit = 10)
    communications.recent.limit(limit)
  end
  
  def email_communications
    communications.email
  end
  
  def sms_communications
    communications.sms
  end
  
  def outbound_communications
    communications.outbound
  end
  
  def inbound_communications
    communications.inbound
  end
  
  # Communication preferences
  def communication_preference_for(channel:, category: nil)
    CommunicationPreferenceService.preference_for(
      recipient: self,
      channel: channel,
      category: category
    )
  end
  
  def can_receive_communication?(channel:, category: nil)
    CommunicationPreferenceService.can_send_to?(
      recipient: self,
      channel: channel,
      category: category
    )
  end
  
  def opt_in_to_communication!(channel:, category: nil, **details)
    CommunicationPreferenceService.opt_in(
      recipient: self,
      channel: channel,
      category: category,
      **details
    )
  end
  
  def opt_out_of_communication!(channel:, category: nil, reason: nil, **details)
    CommunicationPreferenceService.opt_out(
      recipient: self,
      channel: channel,
      category: category,
      reason: reason,
      **details
    )
  end
  
  # Communication stats
  def communication_stats
    {
      total_sent: communications.outbound.count,
      total_received: communications.inbound.count,
      emails_sent: communications.outbound.email.count,
      sms_sent: communications.outbound.sms.count,
      delivered_count: communications.delivered.count,
      failed_count: communications.failed.count,
      last_communication_at: communications.recent.first&.created_at
    }
  end
  
  # Email-specific helper
  def primary_email
    # Override in including class to provide primary email
    # e.g., for Lead: email
    # e.g., for Account: primary_contact&.email
    raise NotImplementedError, "#{self.class.name} must implement #primary_email"
  end
  
  # SMS-specific helper  
  def primary_phone
    # Override in including class to provide primary phone
    # e.g., for Lead: phone
    # e.g., for Account: primary_contact&.phone
    raise NotImplementedError, "#{self.class.name} must implement #primary_phone"
  end
end
