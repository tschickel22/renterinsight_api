class AddTicketNumberToServiceTickets < ActiveRecord::Migration[8.0]
  def up
    add_column :service_tickets, :ticket_number, :string
    add_index :service_tickets, :ticket_number, unique: true
    add_index :service_tickets, [:company_id, :ticket_number]
    
    # Backfill existing tickets with ticket numbers
    reversible do |dir|
      dir.up do
        # Group tickets by company and generate numbers
        ServiceTicket.find_each do |ticket|
          next if ticket.ticket_number.present?
          
          # Use created_at date for the ticket number
          date_part = ticket.created_at.strftime('%Y%m%d')
          
          # Find the highest ticket number for this company and date
          last_ticket = ServiceTicket
                          .where(company_id: ticket.company_id)
                          .where("ticket_number LIKE ?", "ST-#{date_part}-%")
                          .order(ticket_number: :desc)
                          .first
          
          sequence = if last_ticket && last_ticket.ticket_number =~ /ST-\d{8}-(\d{4})$/
            $1.to_i + 1
          else
            1
          end
          
          ticket.update_column(:ticket_number, "ST-#{date_part}-#{sequence.to_s.rjust(4, '0')}")
        end
      end
    end
  end
  
  def down
    remove_index :service_tickets, :ticket_number
    remove_index :service_tickets, [:company_id, :ticket_number]
    remove_column :service_tickets, :ticket_number
  end
end
