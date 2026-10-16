# frozen_string_literal: true

# Postgres NOTIFY refuses a payload of 8000 bytes or more, and the error would
# fail whatever job or request sent the pop-up (config/cable.yml). A pop-up
# that large is skipped and logged instead; the notification itself is still
# saved and shows in the bell.
Rails.application.config.after_initialize do
  require 'action_cable/subscription_adapter/postgresql'

  ActionCable::SubscriptionAdapter::PostgreSQL.prepend(Module.new do
    def broadcast(channel, payload)
      if payload.to_s.bytesize >= 7_900
        Rails.logger.warn("[ActionCable] skipped a #{payload.to_s.bytesize}-byte broadcast on #{channel} (Postgres limit 8000)")
        return
      end
      super
    end
  end)
end
