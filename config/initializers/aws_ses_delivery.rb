# frozen_string_literal: true

# Registers :aws_ses_sdk as a first-class ActionMailer delivery method so async
# jobs (and mailers outside the platform Communications controller) can use
# SES without having to lazy-register on every send.
require_relative '../../lib/aws_ses_delivery'

ActiveSupport.on_load(:action_mailer) do
  ActionMailer::Base.add_delivery_method(:aws_ses_sdk, AwsSesDelivery) unless ActionMailer::Base.delivery_methods.key?(:aws_ses_sdk)
end
