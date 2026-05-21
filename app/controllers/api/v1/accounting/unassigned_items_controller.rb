# frozen_string_literal: true

class Api::V1::Accounting::UnassignedItemsController < ApplicationController
  before_action :set_company_scope

  # GET /api/v1/accounting/unassigned_items
  def index
    return unless authorize_action!('accounting', 'read')

    bills = @company.bills.where(is_deleted: false).where(location_id: nil)
    je_lines = JournalEntryLine
                 .joins(:journal_entry)
                 .where(journal_entries: { company_id: @company.id, is_void: false })
                 .where(journal_entry_lines: { location_id: nil })
    recurring_bills = @company.recurring_bills.where(is_active: true).where(location_id: nil)

    je_entries_with_unassigned = je_lines
      .select('journal_entries.id, journal_entries.entry_number, journal_entries.entry_date, journal_entries.memo, COUNT(journal_entry_lines.id) as unassigned_line_count')
      .group('journal_entries.id, journal_entries.entry_number, journal_entries.entry_date, journal_entries.memo')

    render json: {
      summary: {
        bills: bills.count,
        journal_entry_lines: je_lines.count,
        journal_entries: je_entries_with_unassigned.length,
        recurring_bills: recurring_bills.count,
        total: bills.count + je_lines.count + recurring_bills.count
      },
      bills: bills.order(bill_date: :desc).limit(100).as_json(
        only: [:id, :bill_number, :bill_date, :total_amount, :balance_due, :status, :vendor_name, :memo],
        include: { vendor: { only: [:id, :name] } }
      ),
      journal_entries: je_entries_with_unassigned.map do |je|
        {
          id: je.id,
          entry_number: je.entry_number,
          entry_date: je.entry_date,
          memo: je.memo,
          unassigned_line_count: je.unassigned_line_count
        }
      end,
      recurring_bills: recurring_bills.order(:name).limit(50).as_json(
        only: [:id, :name, :amount, :frequency, :next_due_date, :is_active]
      ),
      locations: @company.locations.where(active: true).order(:name).as_json(
        only: [:id, :name, :code]
      )
    }
  end

  # GET /api/v1/accounting/unassigned_items/count
  def count
    return unless authorize_action!('accounting', 'read')

    bills_count = @company.bills.where(is_deleted: false).where(location_id: nil).count
    je_lines_count = JournalEntryLine
                       .joins(:journal_entry)
                       .where(journal_entries: { company_id: @company.id, is_void: false })
                       .where(journal_entry_lines: { location_id: nil })
                       .count
    recurring_count = @company.recurring_bills.where(is_active: true).where(location_id: nil).count

    render json: {
      total: bills_count + je_lines_count + recurring_count,
      bills: bills_count,
      journal_entry_lines: je_lines_count,
      recurring_bills: recurring_count
    }
  end

  # PATCH /api/v1/accounting/unassigned_items/assign
  def assign
    return unless authorize_action!('accounting', 'update')

    items = params[:items] || []
    results = { updated: 0, errors: [] }

    items.each do |item|
      type = item[:type]
      id = item[:id]
      location_id = item[:location_id]

      unless @company.locations.exists?(id: location_id)
        results[:errors] << { type: type, id: id, error: 'Invalid location' }
        next
      end

      begin
        case type
        when 'Bill'
          bill = @company.bills.find(id)
          bill.update!(location_id: location_id)
          if bill.journal_entry_id
            bill.journal_entry.journal_entry_lines.where(location_id: nil).update_all(location_id: location_id)
          end
          if bill.payment_journal_entry_id
            bill.payment_journal_entry.journal_entry_lines.where(location_id: nil).update_all(location_id: location_id)
          end
        when 'JournalEntryLine'
          line = JournalEntryLine.joins(:journal_entry)
                   .where(journal_entries: { company_id: @company.id })
                   .find(id)
          line.update!(location_id: location_id)
        when 'JournalEntry'
          je = @company.journal_entries.find(id)
          je.journal_entry_lines.where(location_id: nil).update_all(location_id: location_id)
        when 'RecurringBill'
          rb = @company.recurring_bills.find(id)
          rb.update!(location_id: location_id)
        else
          results[:errors] << { type: type, id: id, error: 'Unknown type' }
          next
        end
        results[:updated] += 1
      rescue ActiveRecord::RecordNotFound
        results[:errors] << { type: type, id: id, error: 'Not found' }
      rescue => e
        results[:errors] << { type: type, id: id, error: e.message }
      end
    end

    render json: results
  end
end
