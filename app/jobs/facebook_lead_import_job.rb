# frozen_string_literal: true

# Runs FacebookLeads::Import in the background and keeps its progress where
# the settings page can read it (Setting FacebookIntegration/<id>/lead_import).
class FacebookLeadImportJob < ApplicationJob
  queue_as :default

  STATUS_KEY = 'lead_import'

  def self.status_for(integration)
    Setting.get('FacebookIntegration', integration.id, STATUS_KEY) || {}
  end

  def self.write_status(integration, status)
    Setting.set('FacebookIntegration', integration.id, STATUS_KEY, status.deep_stringify_keys)
  end

  def perform(integration_id, dry_run: true, requested_by_id: nil)
    integration = FacebookIntegration.active.find_by(id: integration_id)
    return unless integration

    base = { 'state' => 'running', 'dry_run' => dry_run, 'requested_by_id' => requested_by_id,
             'started_at' => Time.current.iso8601 }
    self.class.write_status(integration, base)

    result = FacebookLeads::Import.new(
      integration, dry_run: dry_run,
      on_progress: ->(progress) { self.class.write_status(integration, base.merge('progress' => progress.as_json)) }
    ).call

    self.class.write_status(integration, base.merge('state' => 'finished', 'finished_at' => Time.current.iso8601,
                                                    'progress' => result.as_json))
  rescue MetaGraphApi::ExpiredTokenError => e
    integration&.update(status: 'expired')
    fail_with(integration, base, "The Facebook connection has expired. Reconnect the Page, then try again. (#{e.message})")
  rescue MetaGraphApi::Error => e
    fail_with(integration, base, "Facebook refused the request: #{e.message}")
  rescue StandardError => e
    Rails.logger.error "[FacebookLeadImportJob] integration=#{integration_id}: #{e.class}: #{e.message}"
    fail_with(integration, base, "The import stopped: #{e.message}")
  end

  private

  def fail_with(integration, base, message)
    return unless integration

    self.class.write_status(integration, (base || {}).merge('state' => 'failed', 'error' => message,
                                                            'finished_at' => Time.current.iso8601))
  end
end
