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

    # Where the company's QuickBooks login lives, or nil: the Company when
    # it is connected there, otherwise its one connected Location. This is
    # the connection the Connect QuickBooks button makes
    # (QuickbooksOauthService), not the unused quickbooks_connections table.
    # Raises when several locations hold different QuickBooks companies,
    # since a switch moves one set of books.
    def self.connection_for(company)
      return company if company.quickbooks_connected?

      locations = company.locations.where.not(quickbooks_realm_id: [nil, '']).select(&:quickbooks_connected?)
      return nil if locations.empty?
      return locations.first if locations.map(&:quickbooks_realm_id).uniq.one?

      raise Error, 'More than one QuickBooks company is connected to your locations. Connect the one you are switching from at the company level, then start again.'
    end

    # True when connection_for finds a login; false (not an error) when the
    # choice is ambiguous, so status screens still render.
    def self.connected?(company)
      connection_for(company).present?
    rescue Error
      false
    end

    def self.adapter_for(company)
      if fixture_mode?
        Accounting::Adapters::QuickbooksOnlineAdapter.new(company, nil, {}, client: FixtureClient.new)
      else
        entity = connection_for(company)
        raise Error, 'QuickBooks Online is not connected. Connect it under Integrations, then start again.' unless entity

        Accounting::Adapters::QuickbooksOnlineAdapter.new(company, nil, {}, client: ConnectedClient.new(entity))
      end
    end
  end
end
