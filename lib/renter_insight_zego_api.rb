# frozen_string_literal: true

# RenterInsightZegoApi - Backwards compatibility wrapper
#
# This class exists for backwards compatibility with existing code that
# references RenterInsightZegoApi. The actual implementation is in
# ZegoPaymentApi (lib/zego_payment_api.rb).
#
# Both files are autoloaded by Rails via config.autoload_lib.
#
# Usage:
#   api = RenterInsightZegoApi.new(company)
#   # Same as: api = ZegoPaymentApi.new(company)
#
class RenterInsightZegoApi < ZegoPaymentApi
  # Inherit all functionality from ZegoPaymentApi
  # No additional methods needed - this is purely for compatibility
end
