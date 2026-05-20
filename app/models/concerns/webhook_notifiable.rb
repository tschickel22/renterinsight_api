# frozen_string_literal: true

# Include this concern in any model that should fire webhook events.
#
# Requirements:
#   - Model must have a `company_id` column
#   - Event name is derived from model class name (Contact → "contact.created")
#
# Usage:
#   class Contact < ApplicationRecord
#     include WebhookNotifiable
#   end
#
# Supports soft delete: if the model has an `is_deleted` column and it changes
# to true, a `.deleted` event is fired instead of `.updated`.
#
# Override `webhook_payload` in your model to customize the payload sent.
#
module WebhookNotifiable
  extend ActiveSupport::Concern

  included do
    after_create_commit :fire_webhook_created,           unless: -> { skip_webhooks }
    after_update_commit :fire_webhook_updated_or_deleted, unless: -> { skip_webhooks }
    after_destroy_commit :fire_webhook_destroyed,         unless: -> { skip_webhooks }
  end

  private

  # Event prefix derived from class name: Contact → "contact", ServiceTicket → "service_ticket"
  def webhook_event_prefix
    self.class.name.underscore
  end

  def fire_webhook_created
    fire_webhook("#{webhook_event_prefix}.created")
  end

  def fire_webhook_updated_or_deleted
    # Detect soft delete: if is_deleted changed to true, fire .deleted event
    if respond_to?(:is_deleted) && is_deleted == true && saved_change_to_attribute?(:is_deleted)
      fire_webhook("#{webhook_event_prefix}.deleted")
    else
      fire_webhook("#{webhook_event_prefix}.updated")
    end
  end

  def fire_webhook_destroyed
    fire_webhook("#{webhook_event_prefix}.deleted")
  end

  def fire_webhook(event)
    return unless respond_to?(:company_id) && company_id.present?

    WebhookService.fire(
      company_id: company_id,
      event: event,
      payload: webhook_payload
    )
  rescue => e
    Rails.logger.error "[WebhookNotifiable] Failed to fire #{event} for #{self.class.name}##{id}: #{e.message}"
  end

  # Override in model to customize payload
  def webhook_payload
    as_json(except: %w[created_at updated_at])
  end
end
