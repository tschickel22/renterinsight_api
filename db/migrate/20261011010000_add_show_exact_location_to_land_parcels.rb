class AddShowExactLocationToLandParcels < ActiveRecord::Migration[8.0]
  # Whether the website shows where a lot is exactly (its address, map pin and
  # Street View) or only the area it's in. On unless a dealer turns it off for
  # a lot they'd rather not point buyers straight to.
  #
  # The Street View spot is saved apart from the pin: Google only finds a view
  # within about 50 m of a point, so a pin in the middle of a lot opens a
  # black screen. Staff pick the view from the road, facing the lot.
  def change
    add_column :land_parcels, :show_exact_location, :boolean, default: true, null: false
    add_column :land_parcels, :street_view_url, :string
  end
end
