# frozen_string_literal: true

# Adds Champion PDP (Product Detail Page) media + brand context columns to vehicles.
#
# The Champion IMS feed only exposes a 4-image carousel subset, but each home's
# PDP at championhomes.com/models/{slug} carries the FULL set: 40+ gallery
# photos, a Matterport 3D tour, a YouTube walkthrough, plus separate elevation
# and floor-plan renderings. ChampionImsSyncService now scrapes the PDP and
# stores the extracted media here.
#
# matterport_url is kept separate from the existing generic virtual_tour_url
# because the frontend embeds Matterport via its own iframe wrapper.
class AddChampionPdpMediaFieldsToVehicles < ActiveRecord::Migration[8.0]
  def change
    add_column :vehicles, :matterport_url,          :string
    add_column :vehicles, :champion_pdp_url,        :string
    add_column :vehicles, :elevation_images,        :jsonb, default: [], null: false
    add_column :vehicles, :champion_series_name,    :string
    add_column :vehicles, :champion_brand_name,     :string
    add_column :vehicles, :champion_brand_logo_url, :string
  end
end
