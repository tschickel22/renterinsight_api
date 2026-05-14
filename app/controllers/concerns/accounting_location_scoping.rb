# frozen_string_literal: true

module AccountingLocationScoping
  extend ActiveSupport::Concern

  private

  # Returns the location_id to use for accounting queries.
  # - nil means "all locations" (no filter)
  # - a numeric ID means filter to that specific location (including the
  #   Corporate location, which is just a normal Location with is_corporate=true)
  def accounting_location_id
    param = params[:accounting_location_id]
    return nil if param.blank? || param == 'all'

    if param == 'corporate'
      corp = @company.locations.corporate.first
      return corp&.id
    end

    param.to_i
  end

  def accounting_location_filtered?
    accounting_location_id.present?
  end

  def filter_je_lines_by_accounting_location(query)
    if accounting_location_filtered?
      query.where(journal_entry_lines: { location_id: accounting_location_id })
    else
      query
    end
  end

  # Returns a relation of journal_entry IDs that have at least one line in the
  # selected accounting location, or nil when no filter is active.
  def je_ids_for_accounting_location
    return nil unless accounting_location_filtered?

    JournalEntryLine
      .joins(:journal_entry)
      .where(journal_entries: { company_id: @company.id })
      .where(location_id: accounting_location_id)
      .select(:journal_entry_id)
      .distinct
  end
end
