# frozen_string_literal: true

require 'rails_helper'

# The app leaves out a tour that runs through a side menu row the company hid,
# so the tour says which menu pages it walks through.
RSpec.describe Tour do
  it 'lists the menu links it points at and the pages it opens' do
    tour = Tour.create!(key: "t-#{SecureRandom.hex(3)}", name: 'T', trigger_type: 'manual')
    [
      ['[data-tour="nav-section:crm-sales"]', nil],
      ['[data-tour="nav:/contacts"]', nil],
      ['[data-tour="contacts-add"]', '/contacts'],
      ['[data-tour="x"]', '/settings?tab=customize']
    ].each_with_index do |(selector, route), i|
      tour.steps.create!(position: i + 1, title: 'S', content: 'C', selector: selector, route: route, placement: 'bottom', highlight_type: 'outline')
    end

    expect(tour.reload.menu_paths).to eq(['/contacts', '/settings'])
  end
end
