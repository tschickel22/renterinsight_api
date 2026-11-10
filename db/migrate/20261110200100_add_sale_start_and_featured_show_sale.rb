# frozen_string_literal: true

# A sale can start on a set day (it already could end on one), and a website's
# featured home can show that home's sale. Both additive, so old and new code
# run side by side during the release.
class AddSaleStartAndFeaturedShowSale < ActiveRecord::Migration[8.0]
  def change
    add_column :vehicles, :special_discount_starts_on, :date
    add_column :website_featured_homes, :show_sale, :boolean, default: false, null: false
  end
end
