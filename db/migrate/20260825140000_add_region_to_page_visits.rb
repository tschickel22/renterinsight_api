# frozen_string_literal: true

# The visitor's state, alongside the country added with it.
#
# Answers the question an ad buyer actually acts on: is the spend reaching the
# states we sell in. Country alone cannot, since essentially all of this traffic
# is one country.
#
# Two letters rather than a display name, because "Colorado" arrives spelled
# more than one way and would split one state across several rows.
#
# City is deliberately absent. Most of this traffic is mobile, where the IP
# resolves to the carrier's regional hub rather than the visitor, so a city
# column would be confidently wrong — and far more identifying for a visit that
# later becomes a named lead.
class AddRegionToPageVisits < ActiveRecord::Migration[8.0]
  def change
    add_column :page_visits, :region, :string, limit: 8
  end
end
