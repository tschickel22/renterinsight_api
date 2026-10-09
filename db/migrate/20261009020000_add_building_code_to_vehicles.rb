class AddBuildingCodeToVehicles < ActiveRecord::Migration[8.0]
  # HUD, modular, park model (ANSI) or either: what a dealer's site filters on
  # when it has a Modular page. See BuildingCode.
  #
  # Backfill from what is already on file:
  #   - Champion rows: the feed's own buildingCode in champion_raw_payload.
  #     Their home_type is NOT used, because the sync wrote 'hud' there when
  #     the feed said nothing.
  #   - Everything else: a home_type that names the code ("Modular",
  #     "Manufactured", "Park Model"). Sizes like "Double Wide" stay blank.
  # Catalog rows fill in on their next sync (IngestionService version bump),
  # and Cavco seeded rows on the next seeder run.
  #
  # Saved inventory layouts are snapshots, so the field is added to their
  # specs section beside Home Type, as AddDepositAmountToPageLayouts did.

  FIELD_ENTRY = {
    'key' => 'building_code', 'type' => 'standard', 'width' => 1, 'visible' => true, 'required' => false
  }.freeze

  def up
    add_column :vehicles, :building_code, :string
    add_index :vehicles, [:company_id, :building_code]

    champion_codes = select_values(<<~SQL)
      SELECT DISTINCT champion_raw_payload->'buildingCode'->>'code' FROM vehicles
      WHERE champion_raw_payload->'buildingCode'->>'code' IS NOT NULL
    SQL
    champion_codes.each do |raw|
      code = BuildingCode.from_label(raw) or next
      execute <<~SQL
        UPDATE vehicles SET building_code = #{quote(code)}
        WHERE building_code IS NULL AND champion_raw_payload->'buildingCode'->>'code' = #{quote(raw)}
      SQL
    end

    select_values("SELECT DISTINCT home_type FROM vehicles WHERE home_type IS NOT NULL").each do |raw|
      code = BuildingCode.from_label(raw) or next
      execute <<~SQL
        UPDATE vehicles SET building_code = #{quote(code)}
        WHERE building_code IS NULL AND home_type = #{quote(raw)}
          AND source NOT IN ('champion_ims', 'champion_ims_clone')
      SQL
    end

    each_inventory_layout do |layout, sections|
      next if sections.any? { |s| Array(s['fields']).any? { |f| f['key'] == 'building_code' } }

      target = sections.find { |s| Array(s['fields']).any? { |f| f['key'] == 'home_type' } } or next
      at = target['fields'].index { |f| f['key'] == 'home_type' }
      target['fields'].insert(at + 1, FIELD_ENTRY.dup)
      save_layout(layout, sections)
    end
  end

  def down
    each_inventory_layout do |layout, sections|
      before = sections.sum { |s| Array(s['fields']).size }
      sections.each { |s| s['fields'] = Array(s['fields']).reject { |f| f['key'] == 'building_code' } }
      save_layout(layout, sections) if sections.sum { |s| s['fields'].size } != before
    end

    remove_index :vehicles, [:company_id, :building_code]
    remove_column :vehicles, :building_code
  end

  private

  def quote(value) = connection.quote(value)

  def each_inventory_layout
    select_rows("SELECT id, layout_data FROM page_layouts WHERE module_name IN ('inventory', 'inventory_mh')").each do |id, data|
      doc = (JSON.parse(data.to_s) rescue nil)
      sections = doc.is_a?(Hash) ? doc['sections'] : nil
      yield([id, doc], sections) if sections.is_a?(Array)
    end
  end

  # Keeps every other key the layout carries; only its sections change.
  def save_layout((id, doc), sections)
    payload = connection.quote(doc.merge('sections' => sections).to_json)
    connection.execute "UPDATE page_layouts SET layout_data = #{payload}::jsonb, updated_at = NOW() WHERE id = #{id.to_i}"
  end
end
