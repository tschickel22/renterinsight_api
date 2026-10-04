# frozen_string_literal: true

module Accounting
  module QboMigration
    # The QuickBooks client the migration reads through. It uses the
    # connection the app's Connect QuickBooks button makes (tokens on the
    # Company or a Location, QuickbooksOauthService), with the same keys and
    # the same sandbox or production switch (QUICKBOOKS_* ENV), so the
    # wizard and Integrations always agree on what is connected.
    #
    # Answers query(sql), report(name, params) and company_info, the
    # interface QuickbooksOnlineAdapter reads through.
    class ConnectedClient
      attr_reader :entity

      def initialize(entity)
        @entity = entity
      end

      def company_info
        api.get_company_info
      end

      def query(sql)
        api.query(sql)
      end

      def report(name, params = {})
        api.get("reports/#{name}", params.compact.transform_keys(&:to_s))
      end

      private

      # Built on first use so an expired token is refreshed then, not when
      # the wizard is merely loaded. QuickbooksApiService raises a bare RuntimeError when the token
      # refresh fails; turn it into an auth error the wizard shows.
      def api
        @api ||= QuickbooksApiService.new(entity)
      rescue QuickbooksApiError
        raise
      rescue RuntimeError => e
        raise QuickbooksAuthError, "QuickBooks needs to be reconnected under Integrations (#{e.message})."
      end
    end
  end
end
