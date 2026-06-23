# frozen_string_literal: true

class PageLayout < ApplicationRecord
  belongs_to :company
  belongs_to :created_by, class_name: 'User', optional: true
  belongs_to :updated_by, class_name: 'User', optional: true

  validates :module_name, presence: true
  validates :layout_type, presence: true
  validates :layout_type, uniqueness: { scope: [:company_id, :module_name] }

  scope :for_module, ->(mod) { where(module_name: mod) }

  # Fields that can NEVER be hidden per module
  PROTECTED_FIELDS = {
    'leads' => %w[first_name last_name email phone].freeze,
    'accounts' => %w[name].freeze,
    'contacts' => %w[first_name last_name email].freeze,
    'deals' => %w[name deal_number].freeze,
    'inventory' => %w[inventory_id year make model listing_type].freeze,
    'inventory_rv' => %w[inventory_id year make model listing_type].freeze,
    'inventory_mh' => %w[inventory_id year make model listing_type].freeze,
    'contractors' => %w[name].freeze
  }.freeze

  LAYOUT_TYPES = %w[detail edit list].freeze

  validates :layout_type, inclusion: { in: LAYOUT_TYPES }

  # Returns the default layout JSON for a given module
  def self.default_layout_for(module_name)
    case module_name
    when 'leads'
      default_leads_layout
    when 'accounts'
      default_accounts_layout
    when 'contacts'
      default_contacts_layout
    when 'deals'
      default_deals_layout
    when 'inventory'
      default_inventory_layout
    when 'inventory_rv'
      default_inventory_rv_layout
    when 'inventory_mh'
      default_inventory_mh_layout
    when 'contractors'
      default_contractors_layout
    else
      { sections: [] }
    end
  end

  private_class_method def self.default_deals_layout
    {
      sections: [
        {
          id: 'deal_info',
          title: 'Deal Information',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'deal_number', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'name', type: 'standard', visible: true, required: true, width: 1 },
            { key: 'customer_name', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'stage', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'value', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'probability', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'deal_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'owner_id', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'created_at', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'billing_address',
          title: 'Billing Address',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'billing_street', type: 'standard', visible: true, required: false, width: 2 },
            { key: 'billing_city', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'billing_state', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'billing_zip', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'billing_country', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'delivery_address',
          title: 'Delivery Address',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'delivery_street', type: 'standard', visible: true, required: false, width: 2 },
            { key: 'delivery_city', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'delivery_state', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'delivery_zip', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'delivery_country', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'deal_dates',
          title: 'Dates',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'expected_close_date', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'delivery_date', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'actual_close_date', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'deal_outcome',
          title: 'Outcome',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'win_reason', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'loss_reason', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'custom_fields',
          title: 'Custom Fields',
          columns: 2,
          collapsed: false,
          fields: []
        }
      ]
    }
  end

  private_class_method def self.default_accounts_layout
    {
      sections: [
        {
          id: 'account_info',
          title: 'Account Information',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'name', type: 'standard', visible: true, required: true, width: 1 },
            { key: 'account_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'email', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'phone', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'website', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'industry', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'details',
          title: 'Account Details',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'status', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'rating', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'ownership', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'source_id', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'owner_id', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'annual_revenue', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'employee_count', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'billing_address',
          title: 'Billing Address',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'billing_street', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'billing_city', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'billing_state', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'billing_postal_code', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'billing_country', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'shipping_address',
          title: 'Shipping Address',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'shipping_street', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'shipping_city', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'shipping_state', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'shipping_postal_code', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'shipping_country', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'notes_section',
          title: 'Notes & Description',
          columns: 1,
          collapsed: false,
          fields: [
            { key: 'description', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'notes', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'custom_fields',
          title: 'Custom Fields',
          columns: 2,
          collapsed: false,
          fields: []
        }
      ]
    }
  end

  private_class_method def self.default_contacts_layout
    {
      sections: [
        {
          id: 'contact_info',
          title: 'Contact Information',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'first_name', type: 'standard', visible: true, required: true, width: 1 },
            { key: 'last_name', type: 'standard', visible: true, required: true, width: 1 },
            { key: 'email', type: 'standard', visible: true, required: true, width: 1 },
            { key: 'phone', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'details',
          title: 'Contact Details',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'title', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'department', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'company_name', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'account_id', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'owner_id', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'is_primary', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'home_preferences',
          title: 'Home Preferences',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'preferred_vehicle_id', type: 'standard', visible: true, required: false, width: 2 },
            { key: 'budget_range', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'preferred_home_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'preferred_bedrooms', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'preferred_bathrooms', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'preferred_min_sqft', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'preferred_max_sqft', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'billing_address',
          title: 'Billing Address',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'street', type: 'standard', visible: true, required: false, width: 2 },
            { key: 'city', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'state', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'zip', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'country', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'delivery_address',
          title: 'Delivery Address',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'delivery_street', type: 'standard', visible: true, required: false, width: 2 },
            { key: 'delivery_city', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'delivery_state', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'delivery_zip', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'delivery_country', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'preferences',
          title: 'Preferences',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'opt_out_email', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'opt_out_sms', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'notes_section',
          title: 'Notes',
          columns: 1,
          collapsed: false,
          fields: [
            { key: 'notes', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'custom_fields',
          title: 'Custom Fields',
          columns: 2,
          collapsed: false,
          fields: []
        }
      ]
    }
  end

  private_class_method def self.default_inventory_layout
    {
      sections: [
        # === DETAILS TAB ===
        {
          id: 'basic_info',
          title: 'Basic Information',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'inventory_id', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'stock_number', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'year', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'make', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'model', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'trim', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'listing_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'status', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'condition', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'color', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'vin', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'serial_number', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'location_id', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'date_in_stock', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'date_sold', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'listing_url', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'description_notes',
          title: 'Description & Notes',
          columns: 1,
          collapsed: false,
          fields: [
            { key: 'description', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'notes', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },

        # === SPECS TAB ===
        {
          id: 'rv_specs',
          title: 'RV Specifications',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'rv_class', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'rv_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'body_style', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'vehicle_configuration', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'mileage', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'mileage_unit', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'fuel_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'transmission', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'engine_make', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'engine_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'exterior_color', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'interior_color', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'vehicle_interior_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'length', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'weight', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'sleeps', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'sleeping_capacity', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'slide_outs', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'slideouts', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'number_of_doors', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'seating_capacity', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'awning', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'awnings', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'num_air_conditioners', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'leveling_jacks', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'self_contained', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'solar_panels', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'backup_camera', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'satellite_tv', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'mh_specs',
          title: 'MH Specifications',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'home_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'dwelling_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'foundation_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'sections', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'bedrooms', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'bathrooms', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'square_feet', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'width', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'length', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'width1', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'length1', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'width2', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'length2', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'width3', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'length3', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'master_bedroom_location', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'construction',
          title: 'Construction & Materials',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'exterior_material', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'roof_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'roof_material', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'siding_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'flooring_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'insulation_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'ceiling_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'wall_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'heating_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'cooling_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'water_heater_type', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'water_tanks',
          title: 'Water & Tanks',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'fresh_water_capacity', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'gray_water_capacity', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'black_water_capacity', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'propane_capacity', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'weights',
          title: 'Weights',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'dry_weight', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'gross_weight', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'hitch_weight', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'cargo_capacity', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'generator',
          title: 'Generator',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'generator', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'generator_make', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'generator_hours', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'generator_fuel_type', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'amenities',
          title: 'Amenities',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'fireplace', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'central_air', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'deck', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'patio', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'garage', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'carport', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'has_storage', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'thermopane', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'gutters', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'shutters', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'cathedral_ceiling', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'ceiling_fan', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'skylight', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'walkin_closet', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'laundry_room', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'pantry', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'sun_room', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'basement', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'garden_tub', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'appliances',
          title: 'Appliances',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'refrigerator', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'microwave', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'oven', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'dishwasher', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'garbage_disposal', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'clothes_washer', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'clothes_dryer', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'special_features',
          title: 'Special Features',
          columns: 1,
          collapsed: false,
          fields: [
            { key: 'special_features', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'overlay_text', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },

        # === PRICING TAB ===
        {
          id: 'pricing',
          title: 'Pricing',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'sale_price', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'msrp', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'cost', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'rent_price', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'rent_to_own_price', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'deposit_amount', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'lot_rent', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'utilities', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'price_currency', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'sale_pending', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'repo', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'package_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'terms', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'cost_details',
          title: 'Cost Details',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'dealer_cost', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'freight_cost', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'pdi_cost', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'total_cost', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'holdback_amount', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'floor_plan_rate', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'target_gross', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'minimum_price', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },

        # === LOCATION TAB ===
        {
          id: 'address_info',
          title: 'Address Information',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'use_location_address', type: 'standard', visible: true, required: false, width: 2 },
            { key: 'address1', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'address2', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'location_city', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'location_state', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'location_zip', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'county_name', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'location_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'community_name', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'community_key', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },

        # === SELLER TAB ===
        {
          id: 'seller_info',
          title: 'Seller Information',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'seller_name', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'seller_phone', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'seller_address_street', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'seller_address_city', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'seller_address_state', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'seller_address_zip', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },

        # === MEDIA TAB ===
        {
          id: 'media_links',
          title: 'Media Links',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'video_url', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'virtual_tour_url', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },

        # === CUSTOM FIELDS (defaults to details tab) ===
        {
          id: 'custom_fields',
          title: 'Custom Fields',
          columns: 2,
          collapsed: false,
          fields: []
        }
      ]
    }
  end

  private_class_method def self.default_inventory_rv_layout
    {
      sections: [
        # === DETAILS TAB ===
        {
          id: 'basic_info',
          title: 'Basic Information',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'inventory_id', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'stock_number', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'year', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'make', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'model', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'trim', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'listing_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'status', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'condition', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'color', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'vin', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'serial_number', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'location_id', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'date_in_stock', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'date_sold', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'listing_url', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'description_notes',
          title: 'Description & Notes',
          columns: 1,
          collapsed: false,
          fields: [
            { key: 'description', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'notes', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },

        # === SPECS TAB ===
        {
          id: 'rv_specs',
          title: 'RV Specifications',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'rv_class', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'rv_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'body_style', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'vehicle_configuration', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'mileage', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'mileage_unit', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'fuel_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'transmission', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'engine_make', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'engine_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'exterior_color', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'interior_color', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'vehicle_interior_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'length', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'weight', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'sleeps', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'sleeping_capacity', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'slide_outs', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'slideouts', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'number_of_doors', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'seating_capacity', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'awning', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'awnings', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'num_air_conditioners', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'leveling_jacks', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'self_contained', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'solar_panels', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'backup_camera', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'satellite_tv', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'water_tanks',
          title: 'Water & Tanks',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'fresh_water_capacity', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'gray_water_capacity', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'black_water_capacity', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'propane_capacity', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'weights',
          title: 'Weights',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'dry_weight', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'gross_weight', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'hitch_weight', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'cargo_capacity', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'generator',
          title: 'Generator',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'generator', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'generator_make', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'generator_hours', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'generator_fuel_type', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },

        # === PRICING TAB ===
        {
          id: 'pricing',
          title: 'Pricing',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'sale_price', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'msrp', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'cost', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'rent_price', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'rent_to_own_price', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'deposit_amount', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'lot_rent', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'utilities', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'price_currency', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'sale_pending', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'repo', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'package_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'terms', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'cost_details',
          title: 'Cost Details',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'dealer_cost', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'freight_cost', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'pdi_cost', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'total_cost', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'holdback_amount', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'floor_plan_rate', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'target_gross', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'minimum_price', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },

        # === LOCATION TAB ===
        {
          id: 'address_info',
          title: 'Address Information',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'use_location_address', type: 'standard', visible: true, required: false, width: 2 },
            { key: 'address1', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'address2', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'location_city', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'location_state', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'location_zip', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'county_name', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'location_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'community_name', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'community_key', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },

        # === SELLER TAB ===
        {
          id: 'seller_info',
          title: 'Seller Information',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'seller_name', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'seller_phone', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'seller_address_street', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'seller_address_city', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'seller_address_state', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'seller_address_zip', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },

        # === MEDIA TAB ===
        {
          id: 'media_links',
          title: 'Media Links',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'video_url', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'virtual_tour_url', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },

        # === CUSTOM FIELDS ===
        {
          id: 'custom_fields',
          title: 'Custom Fields',
          columns: 2,
          collapsed: false,
          fields: []
        }
      ]
    }
  end

  private_class_method def self.default_inventory_mh_layout
    {
      sections: [
        # === DETAILS TAB ===
        {
          id: 'basic_info',
          title: 'Basic Information',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'inventory_id', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'stock_number', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'year', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'make', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'model', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'trim', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'listing_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'status', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'condition', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'color', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'vin', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'serial_number', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'location_id', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'date_in_stock', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'date_sold', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'listing_url', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'description_notes',
          title: 'Description & Notes',
          columns: 1,
          collapsed: false,
          fields: [
            { key: 'description', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'notes', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },

        # === SPECS TAB ===
        {
          id: 'mh_specs',
          title: 'Home Specifications',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'home_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'dwelling_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'foundation_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'sections', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'bedrooms', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'bathrooms', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'square_feet', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'master_bedroom_location', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'mh_dimensions',
          title: 'Dimensions',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'length', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'width', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'weight', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'width1', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'length1', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'width2', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'length2', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'width3', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'length3', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'construction',
          title: 'Construction & Materials',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'exterior_material', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'roof_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'roof_material', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'siding_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'flooring_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'insulation_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'ceiling_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'wall_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'heating_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'cooling_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'water_heater_type', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'amenities',
          title: 'Amenities',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'fireplace', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'central_air', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'deck', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'patio', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'garage', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'carport', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'has_storage', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'thermopane', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'gutters', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'shutters', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'cathedral_ceiling', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'ceiling_fan', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'skylight', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'walkin_closet', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'laundry_room', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'pantry', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'sun_room', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'basement', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'garden_tub', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'appliances',
          title: 'Appliances',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'refrigerator', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'microwave', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'oven', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'dishwasher', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'garbage_disposal', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'clothes_washer', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'clothes_dryer', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'special_features',
          title: 'Special Features',
          columns: 1,
          collapsed: false,
          fields: [
            { key: 'special_features', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'overlay_text', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },

        # === PRICING TAB ===
        {
          id: 'pricing',
          title: 'Pricing',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'sale_price', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'msrp', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'cost', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'rent_price', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'rent_to_own_price', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'deposit_amount', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'lot_rent', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'utilities', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'price_currency', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'sale_pending', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'repo', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'package_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'terms', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'cost_details',
          title: 'Cost Details',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'dealer_cost', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'freight_cost', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'pdi_cost', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'total_cost', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'holdback_amount', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'floor_plan_rate', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'target_gross', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'minimum_price', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },

        # === LOCATION TAB ===
        {
          id: 'address_info',
          title: 'Address Information',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'use_location_address', type: 'standard', visible: true, required: false, width: 2 },
            { key: 'address1', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'address2', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'location_city', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'location_state', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'location_zip', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'county_name', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'location_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'community_name', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'community_key', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },

        # === SELLER TAB ===
        {
          id: 'seller_info',
          title: 'Seller Information',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'seller_name', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'seller_phone', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'seller_address_street', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'seller_address_city', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'seller_address_state', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'seller_address_zip', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },

        # === MEDIA TAB ===
        {
          id: 'media_links',
          title: 'Media Links',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'video_url', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'virtual_tour_url', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },

        # === CUSTOM FIELDS ===
        {
          id: 'custom_fields',
          title: 'Custom Fields',
          columns: 2,
          collapsed: false,
          fields: []
        }
      ]
    }
  end

  private_class_method def self.default_contractors_layout
    {
      sections: [
        # Overview tab fields
        {
          id: 'contact_info',
          title: 'Contact Information',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'name', type: 'standard', visible: true, required: true, width: 1 },
            { key: 'contact_name', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'email', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'phone', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'trade_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'status', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'hourly_rate', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'rating', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'notes_section',
          title: 'Notes',
          columns: 1,
          collapsed: false,
          fields: [
            { key: 'notes', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        # Credentials & Insurance tab fields
        {
          id: 'license_info',
          title: 'License',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'license_number', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'license_state', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'license_expiry', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'insurance_info',
          title: 'Insurance',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'insurance_provider', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'insurance_policy_number', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'insurance_expiry', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'bond_info',
          title: 'Bond',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'bonded', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'bond_amount', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'bond_expiry', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        # Custom fields — admin can add to any section, or create new ones
        {
          id: 'custom_fields',
          title: 'Custom Fields',
          columns: 2,
          collapsed: false,
          fields: []
        }
      ]
    }
  end

  private_class_method def self.default_leads_layout
    {
      sections: [
        {
          id: 'contact_info',
          title: 'Contact Information',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'first_name', type: 'standard', visible: true, required: true, width: 1 },
            { key: 'last_name', type: 'standard', visible: true, required: true, width: 1 },
            { key: 'email', type: 'standard', visible: true, required: true, width: 1 },
            { key: 'phone', type: 'standard', visible: true, required: true, width: 1 },
            # Co-applicant (co-borrower) — optional; converts to a 2nd contact
            { key: 'co_applicant_first_name', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'co_applicant_last_name', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'co_applicant_email', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'co_applicant_phone', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'details',
          title: 'Lead Details',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'status', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'owner_id', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'source_id', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'company_name', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'title', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'created_at', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'purchase_timeframe', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'rv_experience', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'home_preferences',
          title: 'Home Preferences',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'vehicle_id', type: 'standard', visible: true, required: false, width: 2 },
            { key: 'budget_range', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'preferred_home_type', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'preferred_bedrooms', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'preferred_bathrooms', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'preferred_min_sqft', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'preferred_max_sqft', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'address',
          title: 'Address',
          columns: 2,
          collapsed: false,
          fields: [
            { key: 'street', type: 'standard', visible: true, required: false, width: 2 },
            { key: 'city', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'state', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'zip', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'country', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'notes_section',
          title: 'Notes & Requirements',
          columns: 1,
          collapsed: false,
          fields: [
            { key: 'interests_requirements', type: 'standard', visible: true, required: false, width: 1 },
            { key: 'notes', type: 'standard', visible: true, required: false, width: 1 }
          ]
        },
        {
          id: 'custom_fields',
          title: 'Custom Fields',
          columns: 2,
          collapsed: false,
          fields: []
        }
      ]
    }
  end
end
