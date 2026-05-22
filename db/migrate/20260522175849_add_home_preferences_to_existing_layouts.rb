class AddHomePreferencesToExistingLayouts < ActiveRecord::Migration[8.0]
  def up
    # Fix leads layouts
    PageLayout.where(module_name: 'leads').find_each do |layout|
      data = layout.layout_data
      next unless data.is_a?(Hash)
      sections = data['sections'] || []

      # Skip if home_preferences section already exists
      next if sections.any? { |s| (s['id'] || s[:id]) == 'home_preferences' }

      # Remove vehicle_id and budget_range from details section (moving to home_preferences)
      sections.each do |section|
        if (section['id'] || section[:id]) == 'details'
          fields = section['fields'] || []
          fields.reject! { |f| ['vehicle_id', 'budget_range'].include?(f['key'] || f[:key]) }
          section['fields'] = fields
        end
      end

      # Find insert position (after details, before notes/custom_fields)
      insert_idx = sections.index { |s| ['notes', 'notes_section', 'custom_fields'].include?(s['id'] || s[:id]) } || sections.size

      # Insert home_preferences section
      sections.insert(insert_idx, {
        'id' => 'home_preferences',
        'title' => 'Home Preferences',
        'columns' => 2,
        'collapsed' => false,
        'fields' => [
          { 'key' => 'vehicle_id', 'type' => 'standard', 'visible' => true, 'required' => false, 'width' => 2 },
          { 'key' => 'budget_range', 'type' => 'standard', 'visible' => true, 'required' => false, 'width' => 1 },
          { 'key' => 'preferred_home_type', 'type' => 'standard', 'visible' => true, 'required' => false, 'width' => 1 },
          { 'key' => 'preferred_bedrooms', 'type' => 'standard', 'visible' => true, 'required' => false, 'width' => 1 },
          { 'key' => 'preferred_bathrooms', 'type' => 'standard', 'visible' => true, 'required' => false, 'width' => 1 },
          { 'key' => 'preferred_min_sqft', 'type' => 'standard', 'visible' => true, 'required' => false, 'width' => 1 },
          { 'key' => 'preferred_max_sqft', 'type' => 'standard', 'visible' => true, 'required' => false, 'width' => 1 }
        ]
      })

      data['sections'] = sections
      layout.update_column(:layout_data, data)
    end

    # Fix contacts layouts
    PageLayout.where(module_name: 'contacts').find_each do |layout|
      data = layout.layout_data
      next unless data.is_a?(Hash)
      sections = data['sections'] || []

      next if sections.any? { |s| (s['id'] || s[:id]) == 'home_preferences' }

      # Remove budget_range and preferred_vehicle_id from other sections if present
      sections.each do |section|
        fields = section['fields'] || []
        fields.reject! { |f| ['budget_range', 'preferred_vehicle_id'].include?(f['key'] || f[:key]) }
        section['fields'] = fields
      end

      insert_idx = sections.index { |s| ['notes', 'notes_section', 'custom_fields'].include?(s['id'] || s[:id]) } || sections.size

      sections.insert(insert_idx, {
        'id' => 'home_preferences',
        'title' => 'Home Preferences',
        'columns' => 2,
        'collapsed' => false,
        'fields' => [
          { 'key' => 'preferred_vehicle_id', 'type' => 'standard', 'visible' => true, 'required' => false, 'width' => 2 },
          { 'key' => 'budget_range', 'type' => 'standard', 'visible' => true, 'required' => false, 'width' => 1 },
          { 'key' => 'preferred_home_type', 'type' => 'standard', 'visible' => true, 'required' => false, 'width' => 1 },
          { 'key' => 'preferred_bedrooms', 'type' => 'standard', 'visible' => true, 'required' => false, 'width' => 1 },
          { 'key' => 'preferred_bathrooms', 'type' => 'standard', 'visible' => true, 'required' => false, 'width' => 1 },
          { 'key' => 'preferred_min_sqft', 'type' => 'standard', 'visible' => true, 'required' => false, 'width' => 1 },
          { 'key' => 'preferred_max_sqft', 'type' => 'standard', 'visible' => true, 'required' => false, 'width' => 1 }
        ]
      })

      data['sections'] = sections
      layout.update_column(:layout_data, data)
    end
  end

  def down
    # No rollback needed
  end
end
