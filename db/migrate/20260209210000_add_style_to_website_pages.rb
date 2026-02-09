class AddStyleToWebsitePages < ActiveRecord::Migration[8.0]
  def change
    add_column :website_pages, :style, :jsonb, default: {}
  end
end
