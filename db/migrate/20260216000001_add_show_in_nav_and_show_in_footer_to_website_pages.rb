class AddShowInNavAndShowInFooterToWebsitePages < ActiveRecord::Migration[8.0]
  def change
    add_column :website_pages, :show_in_nav, :boolean, default: true
    add_column :website_pages, :show_in_footer, :boolean, default: true

    # Initialize from existing is_visible value
    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE website_pages SET show_in_nav = is_visible, show_in_footer = is_visible
        SQL
      end
    end
  end
end
