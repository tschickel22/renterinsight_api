# frozen_string_literal: true

# Biometric unlock for the contractor portal.
#
# Contractors reach the portal from an emailed link and a one-time code, so
# "sign in again" means finding that email again. A phone that unlocks with a
# fingerprint removes the step entirely.
#
# Exchange lives on the shared endpoint (Api::V1::DeviceSessionsController), so
# only enrolment and management are here.
module Api
  module Contractor
    class DeviceSessionsController < BaseController
      include DeviceSessionEnrollment

      private

      def device_session_owner
        @current_contractor
      end
    end
  end
end
