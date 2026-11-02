# frozen_string_literal: true

require 'rails_helper'

# Auto numbers restart per company. The database used to require them unique
# across every company, so a second dealer's ticket could fail to save.
RSpec.describe ServiceTicket, 'ticket numbers' do
  def company = Company.create!(name: "Co-#{SecureRandom.hex(3)}", industry: 'manufactured_housing')

  it 'lets two companies have the same number' do
    first = company.service_tickets.create!(title: 'A', description: 'D')
    second = company.service_tickets.create!(title: 'B', description: 'D')
    expect(second.ticket_number).to eq(first.ticket_number)
  end

  it 'still keeps numbers unique within a company' do
    owner = company
    ticket = owner.service_tickets.create!(title: 'A', description: 'D')
    dup = owner.service_tickets.new(title: 'B', description: 'D', ticket_number: ticket.ticket_number)
    expect(dup).not_to be_valid
    expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
