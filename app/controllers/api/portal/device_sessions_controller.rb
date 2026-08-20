# frozen_string_literal: true

# Biometric unlock for the customer portal.
#
# The audience that needs it most: a customer signs in a handful of times across
# a purchase, months apart, which is exactly the person who has forgotten their
# password and bounces off the reset email instead of opening the document
# waiting for them.
#
# Exchange lives on the shared endpoint (Api::V1::DeviceSessionsController), so
# only enrolment and management are here.
module Api
  module Portal
    class DeviceSessionsController < BaseController
      include DeviceSessionEnrollment

      private

      def device_session_owner
        current_buyer_access
      end
    end
  end
end
