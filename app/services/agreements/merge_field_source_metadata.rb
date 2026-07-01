# frozen_string_literal: true

module Agreements
  # Maps every merge field key to its source location in the app UI. Used by the
  # reverse-preview drawer in the agreement template builder and agreement editor:
  # when a rep clicks a placed merge field, the drawer opens to `section`, scrolls
  # to `field_id`, and shows the breadcrumb `path` at the top.
  #
  # Sections correspond to sub-components of the existing Deal / Vehicle / Contact /
  # Account edit forms; the drawer renders the same components in read-only mode
  # (template authoring, no deal loaded) or interactive mode (agreement editing).
  #
  # This is a pure data map — no runtime state. Add new entries here when a new
  # merge field is added in AgreementMergeFieldsController.
  module MergeFieldSourceMetadata
    # Shape: key => { section:, field_id:, path: [breadcrumb...] }
    SECTIONS = {
      # ── Contact ────────────────────────────────────────────────────────────
      'contact.first_name'              => { section: 'contact_identity', field_id: 'first_name', path: ['Contact', 'Identity', 'First Name'] },
      'contact.last_name'               => { section: 'contact_identity', field_id: 'last_name', path: ['Contact', 'Identity', 'Last Name'] },
      'contact.full_name'               => { section: 'contact_identity', field_id: 'full_name', path: ['Contact', 'Identity', 'Full Name'] },
      'contact.email'                   => { section: 'contact_identity', field_id: 'email', path: ['Contact', 'Identity', 'Email'] },
      'contact.phone'                   => { section: 'contact_identity', field_id: 'phone', path: ['Contact', 'Identity', 'Phone'] },
      'contact.mobile_phone'            => { section: 'contact_identity', field_id: 'mobile_phone', path: ['Contact', 'Identity', 'Mobile / Cell Phone'] },
      'contact.title'                   => { section: 'contact_identity', field_id: 'title', path: ['Contact', 'Identity', 'Title'] },
      'contact.department'              => { section: 'contact_identity', field_id: 'department', path: ['Contact', 'Identity', 'Department'] },
      'contact.company_name'            => { section: 'contact_identity', field_id: 'company_name', path: ['Contact', 'Identity', 'Company Name'] },

      'contact.street'                  => { section: 'contact_mailing_address', field_id: 'street', path: ['Contact', 'Mailing Address', 'Street'] },
      'contact.city'                    => { section: 'contact_mailing_address', field_id: 'city', path: ['Contact', 'Mailing Address', 'City'] },
      'contact.state'                   => { section: 'contact_mailing_address', field_id: 'state', path: ['Contact', 'Mailing Address', 'State'] },
      'contact.zip'                     => { section: 'contact_mailing_address', field_id: 'zip', path: ['Contact', 'Mailing Address', 'ZIP'] },
      'contact.country'                 => { section: 'contact_mailing_address', field_id: 'country', path: ['Contact', 'Mailing Address', 'Country'] },
      'contact.full_address'            => { section: 'contact_mailing_address', field_id: nil, path: ['Contact', 'Mailing Address'] },

      'contact.delivery_street'         => { section: 'contact_delivery_address', field_id: 'delivery_street', path: ['Contact', 'Delivery Address', 'Street'] },
      'contact.delivery_city'           => { section: 'contact_delivery_address', field_id: 'delivery_city', path: ['Contact', 'Delivery Address', 'City'] },
      'contact.delivery_state'          => { section: 'contact_delivery_address', field_id: 'delivery_state', path: ['Contact', 'Delivery Address', 'State'] },
      'contact.delivery_zip'            => { section: 'contact_delivery_address', field_id: 'delivery_zip', path: ['Contact', 'Delivery Address', 'ZIP'] },
      'contact.delivery_country'        => { section: 'contact_delivery_address', field_id: 'delivery_country', path: ['Contact', 'Delivery Address', 'Country'] },
      'contact.full_delivery_address'   => { section: 'contact_delivery_address', field_id: nil, path: ['Contact', 'Delivery Address'] },

      # ── Account ────────────────────────────────────────────────────────────
      'account.name'                    => { section: 'account_identity', field_id: 'name', path: ['Account', 'Identity', 'Name'] },
      'account.account_number'          => { section: 'account_identity', field_id: 'account_number', path: ['Account', 'Identity', 'Account Number'] },
      'account.account_type'            => { section: 'account_identity', field_id: 'account_type', path: ['Account', 'Identity', 'Account Type'] },
      'account.email'                   => { section: 'account_identity', field_id: 'email', path: ['Account', 'Identity', 'Email'] },
      'account.phone'                   => { section: 'account_identity', field_id: 'phone', path: ['Account', 'Identity', 'Phone'] },
      'account.website'                 => { section: 'account_identity', field_id: 'website', path: ['Account', 'Identity', 'Website'] },
      'account.industry'                => { section: 'account_identity', field_id: 'industry', path: ['Account', 'Identity', 'Industry'] },
      'account.rating'                  => { section: 'account_identity', field_id: 'rating', path: ['Account', 'Identity', 'Rating'] },
      'account.ownership'               => { section: 'account_identity', field_id: 'ownership', path: ['Account', 'Identity', 'Ownership'] },
      'account.annual_revenue'          => { section: 'account_identity', field_id: 'annual_revenue', path: ['Account', 'Identity', 'Annual Revenue'] },
      'account.employee_count'          => { section: 'account_identity', field_id: 'employee_count', path: ['Account', 'Identity', 'Employee Count'] },

      'account.billing_street'          => { section: 'account_billing_address', field_id: 'billing_street', path: ['Account', 'Billing Address', 'Street'] },
      'account.billing_city'            => { section: 'account_billing_address', field_id: 'billing_city', path: ['Account', 'Billing Address', 'City'] },
      'account.billing_state'           => { section: 'account_billing_address', field_id: 'billing_state', path: ['Account', 'Billing Address', 'State'] },
      'account.billing_zip'             => { section: 'account_billing_address', field_id: 'billing_postal_code', path: ['Account', 'Billing Address', 'ZIP'] },
      'account.billing_country'         => { section: 'account_billing_address', field_id: 'billing_country', path: ['Account', 'Billing Address', 'Country'] },
      'account.full_billing_address'    => { section: 'account_billing_address', field_id: nil, path: ['Account', 'Billing Address'] },

      'account.shipping_street'         => { section: 'account_shipping_address', field_id: 'shipping_street', path: ['Account', 'Shipping Address', 'Street'] },
      'account.shipping_city'           => { section: 'account_shipping_address', field_id: 'shipping_city', path: ['Account', 'Shipping Address', 'City'] },
      'account.shipping_state'          => { section: 'account_shipping_address', field_id: 'shipping_state', path: ['Account', 'Shipping Address', 'State'] },
      'account.shipping_zip'            => { section: 'account_shipping_address', field_id: 'shipping_postal_code', path: ['Account', 'Shipping Address', 'ZIP'] },
      'account.shipping_country'        => { section: 'account_shipping_address', field_id: 'shipping_country', path: ['Account', 'Shipping Address', 'Country'] },
      'account.full_shipping_address'   => { section: 'account_shipping_address', field_id: nil, path: ['Account', 'Shipping Address'] },

      # ── Deal → Basics / Ownership ──────────────────────────────────────────
      'deal.name'                       => { section: 'deal_basics', field_id: 'name', path: ['Deal', 'Basics', 'Deal Name'] },
      'deal.deal_number'                => { section: 'deal_basics', field_id: 'deal_number', path: ['Deal', 'Basics', 'Deal Number'] },
      'deal.stage'                      => { section: 'deal_basics', field_id: 'stage', path: ['Deal', 'Basics', 'Stage'] },
      'deal.close_date'                 => { section: 'deal_basics', field_id: 'expected_close_date', path: ['Deal', 'Basics', 'Expected Close Date'] },
      'deal.delivery_date'              => { section: 'deal_basics', field_id: 'delivery_date', path: ['Deal', 'Basics', 'Delivery Date'] },
      'deal.deal_type'                  => { section: 'deal_basics', field_id: 'deal_type', path: ['Deal', 'Basics', 'Deal Type'] },
      'deal.probability'                => { section: 'deal_basics', field_id: 'probability', path: ['Deal', 'Basics', 'Probability'] },
      'deal.owner_name'                 => { section: 'deal_owner', field_id: 'assigned_to', path: ['Deal', 'Sales Person'] },
      'deal.customer_name'              => { section: 'deal_customer', field_id: 'customer', path: ['Deal', 'Customer'] },

      # ── Deal → Economics ───────────────────────────────────────────────────
      'deal.amount'                     => { section: 'deal_economics', field_id: 'amount', path: ['Deal', 'Economics', 'Deal Amount'] },
      'deal.selling_price'              => { section: 'deal_economics', field_id: 'selling_price', path: ['Deal', 'Economics', 'Selling Price'] },
      'deal.unit_cost'                  => { section: 'deal_economics', field_id: 'unit_cost', path: ['Deal', 'Economics', 'Unit Cost'] },
      'deal.trade_allowance'            => { section: 'deal_economics', field_id: 'trade_allowance', path: ['Deal', 'Economics', 'Trade-In Allowance'] },
      'deal.trade_payoff'               => { section: 'deal_economics', field_id: 'trade_payoff', path: ['Deal', 'Economics', 'Trade Payoff'] },
      # Removed: doc_fee, delivery_fee, setup_fee, skirting_fee, accessories_total,
      # pack_amount, finance_reserve — Phase 3 moved these onto line items.
      'deal.dealer_discount'            => { section: 'deal_economics', field_id: 'dealer_discount', path: ['Deal', 'Economics', 'Discounts', 'Dealer'] },
      'deal.sales_event_discount'       => { section: 'deal_economics', field_id: 'sales_event_discount', path: ['Deal', 'Economics', 'Discounts', 'Sales Event'] },
      'deal.manager_discount'           => { section: 'deal_economics', field_id: 'manager_discount', path: ['Deal', 'Economics', 'Discounts', 'Manager'] },
      'deal.preferred_payment_discount' => { section: 'deal_economics', field_id: 'preferred_payment_discount', path: ['Deal', 'Economics', 'Discounts', 'Preferred Payment'] },
      'deal.multi_unit_discount'        => { section: 'deal_economics', field_id: 'multi_unit_discount', path: ['Deal', 'Economics', 'Discounts', 'Multi-Unit'] },
      # Removed: subtotal_1, subtotal_2 — no longer on DealForm.
      'deal.tax_amount'                 => { section: 'deal_economics', field_id: 'tax_amount', path: ['Deal', 'Economics', 'Tax'] },
      'deal.total_amount'               => { section: 'deal_economics', field_id: 'total_amount', path: ['Deal', 'Economics', 'Total Amount'] },
      'deal.down_payment'               => { section: 'deal_economics', field_id: 'down_payment', path: ['Deal', 'Economics', 'Down Payment'] },
      'deal.additional_payment'         => { section: 'deal_economics', field_id: 'additional_payment', path: ['Deal', 'Economics', 'Additional Payment'] },
      'deal.unpaid_balance'             => { section: 'deal_economics', field_id: 'unpaid_balance', path: ['Deal', 'Economics', 'Unpaid Balance'] },
      'deal.discounted_price'           => { section: 'deal_economics', field_id: nil, path: ['Deal', 'Economics', 'Discounted Price (derived)'] },
      'deal.total_home_price'           => { section: 'deal_economics', field_id: nil, path: ['Deal', 'Economics', 'Total Home Price (derived)'] },

      # ── Deal → Delivery / Billing address blocks ──────────────────────────
      'deal.delivery_street'            => { section: 'deal_delivery', field_id: 'delivery_street', path: ['Deal', 'Delivery Address', 'Street'] },
      'deal.delivery_city'              => { section: 'deal_delivery', field_id: 'delivery_city', path: ['Deal', 'Delivery Address', 'City'] },
      'deal.delivery_state'             => { section: 'deal_delivery', field_id: 'delivery_state', path: ['Deal', 'Delivery Address', 'State'] },
      'deal.delivery_zip'               => { section: 'deal_delivery', field_id: 'delivery_zip', path: ['Deal', 'Delivery Address', 'ZIP'] },
      'deal.billing_street'             => { section: 'deal_billing', field_id: 'billing_street', path: ['Deal', 'Billing Address', 'Street'] },
      'deal.billing_city'               => { section: 'deal_billing', field_id: 'billing_city', path: ['Deal', 'Billing Address', 'City'] },
      'deal.billing_state'              => { section: 'deal_billing', field_id: 'billing_state', path: ['Deal', 'Billing Address', 'State'] },
      'deal.billing_zip'                => { section: 'deal_billing', field_id: 'billing_zip', path: ['Deal', 'Billing Address', 'ZIP'] },

      # ── Deal → Line Items (all point at the Line Items card) ───────────────
      # Removed: addendum_items, addendum_total — superseded by line_items below.
      'deal.line_items'                 => { section: 'deal_line_items', field_id: nil, path: ['Deal', 'Line Items'] },
      'deal.home_line_item'             => { section: 'deal_line_items', field_id: nil, path: ['Deal', 'Line Items', 'Home Row'] },
      'deal.non_home_line_items'        => { section: 'deal_line_items', field_id: nil, path: ['Deal', 'Line Items', 'Non-Home Rows'] },
      'deal.line_items_home'            => { section: 'deal_line_items', field_id: nil, path: ['Deal', 'Line Items', 'Category: Home'] },
      'deal.line_items_land'            => { section: 'deal_line_items', field_id: nil, path: ['Deal', 'Line Items', 'Category: Land / Site Improvements'] },
      'deal.line_items_fee'             => { section: 'deal_line_items', field_id: nil, path: ['Deal', 'Line Items', 'Category: Fees'] },
      'deal.line_items_accessory'       => { section: 'deal_line_items', field_id: nil, path: ['Deal', 'Line Items', 'Category: Accessories'] },
      'deal.line_items_service'         => { section: 'deal_line_items', field_id: nil, path: ['Deal', 'Line Items', 'Category: Services'] },
      'deal.line_items_product'         => { section: 'deal_line_items', field_id: nil, path: ['Deal', 'Line Items', 'Category: Products'] },
      'deal.line_items_other'           => { section: 'deal_line_items', field_id: nil, path: ['Deal', 'Line Items', 'Category: Other'] },
      'deal.home_total'                 => { section: 'deal_line_items', field_id: nil, path: ['Deal', 'Line Items', 'Home Total'] },
      'deal.non_home_line_items_total'  => { section: 'deal_line_items', field_id: nil, path: ['Deal', 'Line Items', 'Non-Home Subtotal'] },
      'deal.line_items_total'           => { section: 'deal_line_items', field_id: nil, path: ['Deal', 'Line Items', 'Subtotal (All)'] },
      'deal.land_total'                 => { section: 'deal_line_items', field_id: nil, path: ['Deal', 'Line Items', 'Land Subtotal'] },
      'deal.fee_total'                  => { section: 'deal_line_items', field_id: nil, path: ['Deal', 'Line Items', 'Fees Subtotal'] },
      'deal.accessory_total_from_lines' => { section: 'deal_line_items', field_id: nil, path: ['Deal', 'Line Items', 'Accessories Subtotal'] },
      'deal.service_total'              => { section: 'deal_line_items', field_id: nil, path: ['Deal', 'Line Items', 'Services Subtotal'] },
      'deal.product_total'              => { section: 'deal_line_items', field_id: nil, path: ['Deal', 'Line Items', 'Products Subtotal'] },
      'deal.other_total'                => { section: 'deal_line_items', field_id: nil, path: ['Deal', 'Line Items', 'Other Subtotal'] },

      # ── Vehicle (Home) ─────────────────────────────────────────────────────
      'vehicle.make'                    => { section: 'vehicle_identity', field_id: 'make', path: ['Vehicle', 'Identity', 'Make'] },
      'vehicle.model'                   => { section: 'vehicle_identity', field_id: 'model', path: ['Vehicle', 'Identity', 'Model'] },
      'vehicle.trim'                    => { section: 'vehicle_identity', field_id: 'trim', path: ['Vehicle', 'Identity', 'Trim'] },
      'vehicle.year'                    => { section: 'vehicle_identity', field_id: 'year', path: ['Vehicle', 'Identity', 'Year'] },
      'vehicle.vin'                     => { section: 'vehicle_identity', field_id: 'vin', path: ['Vehicle', 'Identity', 'VIN'] },
      'vehicle.serial_number'           => { section: 'vehicle_identity', field_id: 'serial_number', path: ['Vehicle', 'Identity', 'Serial Number'] },
      'vehicle.stock_number'            => { section: 'vehicle_identity', field_id: 'stock_number', path: ['Vehicle', 'Identity', 'Stock Number'] },
      'vehicle.inventory_id'            => { section: 'vehicle_identity', field_id: 'inventory_id', path: ['Vehicle', 'Identity', 'Inventory ID'] },
      'vehicle.condition'               => { section: 'vehicle_identity', field_id: 'condition', path: ['Vehicle', 'Identity', 'New / Used'] },
      'vehicle.status'                  => { section: 'vehicle_identity', field_id: 'status', path: ['Vehicle', 'Identity', 'Status'] },

      'vehicle.sections'                => { section: 'vehicle_dimensions', field_id: 'sections', path: ['Vehicle', 'Dimensions', 'Sections'] },
      'vehicle.bedrooms'                => { section: 'vehicle_dimensions', field_id: 'bedrooms', path: ['Vehicle', 'Dimensions', 'Bedrooms'] },
      'vehicle.bathrooms'               => { section: 'vehicle_dimensions', field_id: 'bathrooms', path: ['Vehicle', 'Dimensions', 'Bathrooms'] },
      'vehicle.length'                  => { section: 'vehicle_dimensions', field_id: 'length', path: ['Vehicle', 'Dimensions', 'Length'] },
      'vehicle.width'                   => { section: 'vehicle_dimensions', field_id: 'width', path: ['Vehicle', 'Dimensions', 'Width'] },
      'vehicle.floor_size'              => { section: 'vehicle_dimensions', field_id: nil, path: ['Vehicle', 'Dimensions', 'Floor Size'] },
      'vehicle.square_feet'             => { section: 'vehicle_dimensions', field_id: 'square_feet', path: ['Vehicle', 'Dimensions', 'Approx Sq Ft'] },
      'vehicle.sleeps'                  => { section: 'vehicle_dimensions', field_id: 'sleeps', path: ['Vehicle', 'Dimensions', 'Sleeps'] },

      'vehicle.exterior_color'          => { section: 'vehicle_appearance', field_id: 'exterior_color', path: ['Vehicle', 'Appearance', 'Exterior Color'] },
      'vehicle.interior_color'          => { section: 'vehicle_appearance', field_id: 'interior_color', path: ['Vehicle', 'Appearance', 'Interior Color'] },
      'vehicle.exterior_material'       => { section: 'vehicle_appearance', field_id: 'exterior_material', path: ['Vehicle', 'Appearance', 'Exterior Material'] },
      'vehicle.roof_material'           => { section: 'vehicle_appearance', field_id: 'roof_material', path: ['Vehicle', 'Appearance', 'Roof Material'] },

      'vehicle.home_type'               => { section: 'vehicle_construction', field_id: 'home_type', path: ['Vehicle', 'Construction', 'Home Type'] },
      'vehicle.dwelling_type'           => { section: 'vehicle_construction', field_id: 'dwelling_type', path: ['Vehicle', 'Construction', 'Dwelling Type'] },
      'vehicle.body_style'              => { section: 'vehicle_construction', field_id: 'body_style', path: ['Vehicle', 'Construction', 'Body Style'] },
      'vehicle.foundation_type'         => { section: 'vehicle_construction', field_id: 'foundation_type', path: ['Vehicle', 'Construction', 'Foundation Type'] },
      'vehicle.insulation_r_roof'       => { section: 'vehicle_construction', field_id: 'insulation_r_roof', path: ['Vehicle', 'Construction', 'Insulation', 'Roof R-Value'] },
      'vehicle.insulation_r_wall'       => { section: 'vehicle_construction', field_id: 'insulation_r_wall', path: ['Vehicle', 'Construction', 'Insulation', 'Wall R-Value'] },
      'vehicle.insulation_r_floor'      => { section: 'vehicle_construction', field_id: 'insulation_r_floor', path: ['Vehicle', 'Construction', 'Insulation', 'Floor R-Value'] },
      'vehicle.insulation_type'         => { section: 'vehicle_construction', field_id: 'insulation_type', path: ['Vehicle', 'Construction', 'Insulation', 'Type'] },
      'vehicle.floor_joist_size'        => { section: 'vehicle_construction', field_id: 'floor_joist_size', path: ['Vehicle', 'Construction', 'Floor Joist Size'] },
      'vehicle.electrical_service'      => { section: 'vehicle_construction', field_id: 'electrical_service', path: ['Vehicle', 'Construction', 'Electrical Service'] },

      'vehicle.flooring_type'           => { section: 'vehicle_features', field_id: 'flooring_type', path: ['Vehicle', 'Interior Features', 'Flooring'] },
      'vehicle.heating_type'            => { section: 'vehicle_features', field_id: 'heating_type', path: ['Vehicle', 'Interior Features', 'Heating'] },
      'vehicle.cooling_type'            => { section: 'vehicle_features', field_id: 'cooling_type', path: ['Vehicle', 'Interior Features', 'Cooling'] },
      'vehicle.water_heater_type'       => { section: 'vehicle_features', field_id: 'water_heater_type', path: ['Vehicle', 'Interior Features', 'Water Heater'] },
      'vehicle.ceiling_type'            => { section: 'vehicle_features', field_id: 'ceiling_type', path: ['Vehicle', 'Interior Features', 'Ceiling'] },
      'vehicle.wall_type'               => { section: 'vehicle_features', field_id: 'wall_type', path: ['Vehicle', 'Interior Features', 'Wall'] },
      'vehicle.master_bedroom_location' => { section: 'vehicle_features', field_id: 'master_bedroom_location', path: ['Vehicle', 'Interior Features', 'Master Bedroom Location'] },

      'vehicle.refrigerator'            => { section: 'vehicle_appliances', field_id: 'refrigerator', path: ['Vehicle', 'Appliances', 'Refrigerator'] },
      'vehicle.dishwasher'              => { section: 'vehicle_appliances', field_id: 'dishwasher', path: ['Vehicle', 'Appliances', 'Dishwasher'] },
      'vehicle.microwave'               => { section: 'vehicle_appliances', field_id: 'microwave', path: ['Vehicle', 'Appliances', 'Microwave'] },
      'vehicle.oven'                    => { section: 'vehicle_appliances', field_id: 'oven', path: ['Vehicle', 'Appliances', 'Oven / Range'] },
      'vehicle.garbage_disposal'        => { section: 'vehicle_appliances', field_id: 'garbage_disposal', path: ['Vehicle', 'Appliances', 'Garbage Disposal'] },
      'vehicle.clothes_washer'          => { section: 'vehicle_appliances', field_id: 'clothes_washer', path: ['Vehicle', 'Appliances', 'Clothes Washer'] },
      'vehicle.clothes_dryer'           => { section: 'vehicle_appliances', field_id: 'clothes_dryer', path: ['Vehicle', 'Appliances', 'Clothes Dryer'] },
      'vehicle.fireplace'               => { section: 'vehicle_appliances', field_id: 'fireplace', path: ['Vehicle', 'Appliances', 'Fireplace'] },
      'vehicle.central_air'             => { section: 'vehicle_appliances', field_id: 'central_air', path: ['Vehicle', 'Appliances', 'Central Air'] },
      'vehicle.garden_tub'              => { section: 'vehicle_appliances', field_id: 'garden_tub', path: ['Vehicle', 'Appliances', 'Garden Tub'] },

      'vehicle.msrp'                    => { section: 'vehicle_pricing', field_id: 'msrp', path: ['Vehicle', 'Pricing', 'MSRP'] },
      'vehicle.sale_price'              => { section: 'vehicle_pricing', field_id: 'sale_price', path: ['Vehicle', 'Pricing', 'Sale Price'] },
      'vehicle.cost'                    => { section: 'vehicle_pricing', field_id: 'cost', path: ['Vehicle', 'Pricing', 'Cost'] },
      'vehicle.dealer_cost'             => { section: 'vehicle_pricing', field_id: 'dealer_cost', path: ['Vehicle', 'Pricing', 'Dealer Cost'] },
      'vehicle.freight_cost'            => { section: 'vehicle_pricing', field_id: 'freight_cost', path: ['Vehicle', 'Pricing', 'Freight Cost'] },
      'vehicle.total_cost'              => { section: 'vehicle_pricing', field_id: 'total_cost', path: ['Vehicle', 'Pricing', 'Total Cost'] },
      'vehicle.minimum_price'           => { section: 'vehicle_pricing', field_id: 'minimum_price', path: ['Vehicle', 'Pricing', 'Minimum Price'] },
      'vehicle.deposit_amount'          => { section: 'vehicle_pricing', field_id: 'deposit_amount', path: ['Vehicle', 'Pricing', 'Deposit Amount'] },

      'vehicle.county_name'             => { section: 'vehicle_location', field_id: 'county_name', path: ['Vehicle', 'Location', 'County'] },
      'vehicle.community_name'          => { section: 'vehicle_location', field_id: 'community_name', path: ['Vehicle', 'Location', 'Community / Park Name'] },
      'vehicle.lot_rent'                => { section: 'vehicle_location', field_id: 'lot_rent', path: ['Vehicle', 'Location', 'Lot Rent'] },

      'vehicle.rv_type'                 => { section: 'vehicle_rv', field_id: 'rv_type', path: ['Vehicle', 'RV', 'RV Type'] },
      'vehicle.rv_class'                => { section: 'vehicle_rv', field_id: 'rv_class', path: ['Vehicle', 'RV', 'RV Class'] },
      'vehicle.fuel_type'               => { section: 'vehicle_rv', field_id: 'fuel_type', path: ['Vehicle', 'RV', 'Fuel Type'] },
      'vehicle.transmission'            => { section: 'vehicle_rv', field_id: 'transmission', path: ['Vehicle', 'RV', 'Transmission'] },
      'vehicle.mileage'                 => { section: 'vehicle_rv', field_id: 'mileage', path: ['Vehicle', 'RV', 'Mileage'] },
      'vehicle.weight'                  => { section: 'vehicle_rv', field_id: 'weight', path: ['Vehicle', 'RV', 'Weight'] },
      'vehicle.gross_weight'            => { section: 'vehicle_rv', field_id: 'gross_weight', path: ['Vehicle', 'RV', 'GVWR'] },
      'vehicle.hitch_weight'            => { section: 'vehicle_rv', field_id: 'hitch_weight', path: ['Vehicle', 'RV', 'Hitch Weight'] },
      'vehicle.slide_outs'              => { section: 'vehicle_rv', field_id: 'slide_outs', path: ['Vehicle', 'RV', 'Slide Outs'] },

      # ── Invoice ────────────────────────────────────────────────────────────
      'invoice.number'                  => { section: 'invoice', field_id: 'invoice_number', path: ['Invoice', 'Number'] },
      'invoice.date'                    => { section: 'invoice', field_id: 'invoice_date', path: ['Invoice', 'Date'] },
      'invoice.due_date'                => { section: 'invoice', field_id: 'due_date', path: ['Invoice', 'Due Date'] },
      'invoice.total'                   => { section: 'invoice', field_id: 'total', path: ['Invoice', 'Total'] },
      'invoice.amount_due'              => { section: 'invoice', field_id: 'amount_due', path: ['Invoice', 'Amount Due'] },
      'invoice.draw_schedule_text'      => { section: 'invoice', field_id: 'draw_schedule', path: ['Invoice', 'Draw Schedule'] },

      # ── Company / Date / Agreement / Signer / Custom (no in-app source form) ─
      'company.name'                    => { section: 'company_settings', field_id: 'name', path: ['Settings', 'Company', 'Name'] },
      'company.email'                   => { section: 'company_settings', field_id: 'email', path: ['Settings', 'Company', 'Email'] },
      'company.phone'                   => { section: 'company_settings', field_id: 'phone', path: ['Settings', 'Company', 'Phone'] },
      'company.website'                 => { section: 'company_settings', field_id: 'website', path: ['Settings', 'Company', 'Website'] },
      'company.address'                 => { section: 'company_settings', field_id: 'address', path: ['Settings', 'Company', 'Address'] },

      'date.today'                      => { section: nil, field_id: nil, path: ['System', 'Date', 'Today'] },
      'date.current_year'               => { section: nil, field_id: nil, path: ['System', 'Date', 'Current Year'] },
      'date.current_month'              => { section: nil, field_id: nil, path: ['System', 'Date', 'Current Month'] },

      'agreement.number'                => { section: 'agreement_self', field_id: 'agreement_number', path: ['Agreement', 'Number'] },
      'agreement.title'                 => { section: 'agreement_self', field_id: 'title', path: ['Agreement', 'Title'] },
      'agreement.date'                  => { section: 'agreement_self', field_id: 'date', path: ['Agreement', 'Date'] },
      'agreement.expiry_date'           => { section: 'agreement_self', field_id: 'expiry_date', path: ['Agreement', 'Expiry Date'] },

      'signer.name'                     => { section: nil, field_id: nil, path: ['Signer', 'Name (filled at sign-time)'] },
      'signer.email'                    => { section: nil, field_id: nil, path: ['Signer', 'Email (filled at sign-time)'] },
      'signer.signature'                => { section: nil, field_id: nil, path: ['Signer', 'Signature (drawn at sign-time)'] },
      'signer.initials'                 => { section: nil, field_id: nil, path: ['Signer', 'Initials (drawn at sign-time)'] },
      'signer.signed_date'              => { section: nil, field_id: nil, path: ['Signer', 'Date Signed'] },

      'custom.text_field'               => { section: nil, field_id: nil, path: ['Custom Field', 'Text (preparer fills)'] },
      'custom.date_field'               => { section: nil, field_id: nil, path: ['Custom Field', 'Date (preparer fills)'] },
      'custom.checkbox'                 => { section: nil, field_id: nil, path: ['Custom Field', 'Checkbox (preparer fills)'] },
    }.freeze

    # Lookup helper. Returns nil for unknown keys (e.g., user-defined custom fields
    # via build_entity_custom_fields — those get generic path built at decorate time).
    def self.for(key)
      SECTIONS[key.to_s]
    end
  end
end
