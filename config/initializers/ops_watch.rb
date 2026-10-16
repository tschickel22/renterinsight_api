# frozen_string_literal: true

# Each server error (500) is kept for Ops::Watch, which reports a spike.
ActiveSupport::Notifications.subscribe('process_action.action_controller') do |*, payload|
  Ops::Watch.error!(payload) if payload[:exception_object] || payload[:status].to_i >= 500
end
