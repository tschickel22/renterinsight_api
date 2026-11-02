# frozen_string_literal: true

# Auto numbers restart per company (ST-YYYYMMDD-0001) and the model validates
# uniqueness per company, but the database required them unique across every
# company, so a second dealer's ticket could fail to save. No company has a
# duplicate today (checked 2026-11-02 on staging and production).
class TicketNumbersUniquePerCompany < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    remove_index :service_tickets, name: 'index_service_tickets_on_company_id_and_ticket_number',
                                   algorithm: :concurrently, if_exists: true
    add_index :service_tickets, %i[company_id ticket_number], unique: true,
                                                              name: 'index_service_tickets_on_company_id_and_ticket_number',
                                                              algorithm: :concurrently
    remove_index :service_tickets, name: 'index_service_tickets_on_ticket_number',
                                   algorithm: :concurrently, if_exists: true
  end

  def down; end
end
