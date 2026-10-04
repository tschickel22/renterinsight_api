# frozen_string_literal: true

module Accounting
  # Switching a dealer from QuickBooks Online to DealerTide (backlog E62).
  #
  # A migration is an AccountingImport with source_type 'quickbooks_online'
  # and import_config['mode'] == 'migration'. Its whole working state (the
  # cutover date's trial balance, account rows with suggestion, choice and
  # confirmed, bank matches, uncleared items, fetched lists) lives in
  # import_config, string keyed. Plan: QUICKBOOKS_MIGRATION_PLAN.md beside
  # backlog.md; API contract: the frontend's qbo_migration_contract.md.
  module QboMigration
    FIXTURE_DIR = Rails.root.join('spec/fixtures/quickbooks/migration')

    class Error < StandardError; end

    # QBO_FIXTURE=1 runs the migration against a recorded QuickBooks company
    # instead of the API, so the wizard can be driven end to end without a
    # real connection. Development and test only, never staging or production.
    def self.fixture_mode?
      (Rails.env.development? || Rails.env.test?) && ENV['QBO_FIXTURE'] == '1'
    end

    # The QuickBooks connection a migration needs, or nil.
    def self.connection_for(company)
      connection = QuickbooksConnection.for_company(company.id)
      connection&.connected? ? connection : nil
    end

    def self.adapter_for(company)
      if fixture_mode?
        Accounting::Adapters::QuickbooksOnlineAdapter.new(company, nil, {}, client: FixtureClient.new)
      else
        connection = connection_for(company)
        raise Error, 'QuickBooks Online is not connected. Connect it under Integrations, then start again.' unless connection

        Accounting::Adapters::QuickbooksOnlineAdapter.new(company, connection)
      end
    end
  end
end
