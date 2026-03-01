class FixLeadsLayoutAddVehicleId < ActiveRecord::Migration[8.0]
  def up
    PageLayout.where(module_name: 'leads', layout_type: 'detail').find_each do |layout|
      data = layout.layout_data
      next unless data.is_a?(Hash)

      sections = data['sections'] || data[:sections] || []
      changed = false

      sections.each do |section|
        fields = section['fields'] || section[:fields] || []

        # Remove vehicle_id from contact_info if accidentally placed there
        if (section['id'] || section[:id]) == 'contact_info'
          before = fields.size
          fields.reject! { |f| (f['key'] || f[:key]) == 'vehicle_id' }
          if fields.size != before
            section['fields'] = fields
            changed = true
          end
        end

        # Add vehicle_id to details section if missing
        if (section['id'] || section[:id]) == 'details'
          unless fields.any? { |f| (f['key'] || f[:key]) == 'vehicle_id' }
            fields << { 'key' => 'vehicle_id', 'type' => 'standard', 'visible' => true, 'required' => false, 'width' => 2 }
            section['fields'] = fields
            changed = true
          end
        end
      end

      layout.update_column(:layout_data, data) if changed
    end
  end

  def down
    # Intentionally a no-op
  end
end
