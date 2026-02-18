# frozen_string_literal: true

# Include in partner API controllers to automatically fire webhooks on CUD actions.
#
# Usage:
#   class ContactsController < BaseController
#     include PartnerWebhooks
#     fires_webhooks resource: :contact
#   end
#
# This will fire contact.created, contact.updated, contact.deleted
# after successful create, update, and destroy actions.
module PartnerWebhooks
  extend ActiveSupport::Concern

  included do
    class_attribute :_webhook_resource, instance_writer: false
    after_action :fire_create_webhook, only: :create, if: :successful_response?
    after_action :fire_update_webhook, only: :update, if: :successful_response?
    after_action :fire_destroy_webhook, only: :destroy, if: :successful_response?
  end

  class_methods do
    def fires_webhooks(resource:)
      self._webhook_resource = resource.to_s
    end
  end

  private

  def fire_create_webhook
    fire_webhook("created")
  end

  def fire_update_webhook
    fire_webhook("updated")
  end

  def fire_destroy_webhook
    fire_webhook("deleted")
  end

  def fire_webhook(action)
    return unless self.class._webhook_resource

    event = "#{self.class._webhook_resource}.#{action}"
    payload = webhook_payload

    return unless payload

    WebhookService.fire(
      company_id: current_company_id,
      event: event,
      payload: payload
    )
  end

  # Extract payload from the response body that was just rendered.
  # Looks for the standard { data: ... } envelope.
  def webhook_payload
    body = response.parsed_body
    body["data"] if body.is_a?(Hash)
  rescue
    nil
  end

  def successful_response?
    response.status.in?([200, 201])
  end
end
