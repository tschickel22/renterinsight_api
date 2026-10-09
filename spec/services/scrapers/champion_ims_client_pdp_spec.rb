# frozen_string_literal: true

require 'rails_helper'

# A Champion model page (championhomes.com/models/<slug>) as it is laid out:
# photos in one gallery panel, the floor plan in another, the floor plan named
# "Main_0002_<model number>-" with no alt text.
RSpec.describe Scrapers::ChampionImsClient do
  let(:s7) { 'https://s7d9.scene7.com/is/image/championhomes' }
  let(:html) do
    <<~HTML
      <html><body>
        <div id="panel-photos">
          <img src="#{s7}/Aspire%203272H32186%20Living%20Room%201" alt="Photo by: WindowStill Photography">
          <img src="#{s7}/Aspire%203272H32186%20Bath%201" alt="Photo by: WindowStill Photography">
        </div>
        <div id="panel-floor-plans">
          <img class="cmp-gallery-modal__image" src="#{s7}/Main_0002_3272H32186-"/>
        </div>
        <img src="#{s7}/Main_0000s_0009_Aspire-112AP-1652H21083-Sta" alt="">
      </body></html>
    HTML
  end

  it 'takes the floor plans panel and Main_ renders as floor plans, not gallery photos' do
    media = described_class.new(navision_id: '2264IN').send(:extract_pdp_media, html, nil)
    expect(media[:floor_plans]).to contain_exactly("#{s7}/Main_0002_3272H32186-", "#{s7}/Main_0000s_0009_Aspire-112AP-1652H21083-Sta")
    expect(media[:gallery]).to eq(["#{s7}/Aspire%203272H32186%20Living%20Room%201", "#{s7}/Aspire%203272H32186%20Bath%201"])
  end
end
