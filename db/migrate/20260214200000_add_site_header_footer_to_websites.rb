class AddSiteHeaderFooterToWebsites < ActiveRecord::Migration[8.0]
  def change
    add_column :websites, :site_header, :jsonb, default: {}
    add_column :websites, :site_footer, :jsonb, default: {}
  end
end
