# frozen_string_literal: true

module Catalog
  module PriceBooks
    # Tool schemas for extraction. Proven on the Champion Topeka package
    # (Phase 0, 2026-09-29): base prices and option prices came back exact
    # when read through these; section and package labels are the weak spot.
    module Tools
      SYSTEM = 'You extract manufactured home factory price packages into structured data for human review. ' \
               'Copy model numbers, option text and prices exactly as printed. Never guess or invent a value; ' \
               'if something is unreadable, say so in the uncertain or notes field.'

      PRICE_LIST = {
        name: 'record_price_list',
        description: 'Record every row of a manufactured home base price list page exactly as printed.',
        input_schema: {
          type: 'object',
          required: %w[rows],
          properties: {
            plant: { type: 'string', description: 'Plant or brand in the header, e.g. DUTCH HOUSING, PRIME OF INDIANA' },
            series: { type: 'string', description: 'Series in the header, e.g. ASPIRE HUD - 28 SECTIONAL' },
            building_code: { type: 'string', enum: %w[HUD MOD mixed unknown] },
            effective_date: { type: 'string', description: 'ISO date if printed' },
            fob: { type: 'string' },
            rows: {
              type: 'array',
              items: {
                type: 'object',
                required: %w[model_number net_base_price],
                properties: {
                  model_number: { type: 'string', description: 'Exactly as printed, character for character' },
                  model_name: { type: 'string' },
                  box_width_ft: { type: 'integer' }, box_length_ft: { type: 'integer' },
                  beds: { type: 'integer' }, baths: { type: 'number' },
                  home_type: { type: 'string' },
                  net_base_price: { type: 'number', description: 'The NET base price column, not a total' },
                  required_adders: { type: 'array', items: { type: 'object', properties: { name: { type: 'string' }, amount: { type: 'number' } } } },
                  total_base_price: { type: 'number', description: 'Only when the sheet prints a total after adders' },
                  uncertain: { type: 'string', description: 'Anything you could not read clearly' }
                }
              }
            },
            notes: { type: 'array', items: { type: 'string' } }
          }
        }
      }.freeze

      STANDARDS = {
        name: 'record_standard_features',
        description: 'Record a standard features sheet.',
        input_schema: {
          type: 'object', required: %w[categories],
          properties: {
            series: { type: 'string' }, building_code: { type: 'string' },
            categories: { type: 'array', items: { type: 'object', required: %w[name items],
                                                  properties: { name: { type: 'string' }, items: { type: 'array', items: { type: 'string' } } } } }
          }
        }
      }.freeze

      OPTIONS = {
        name: 'record_options',
        description: 'Record the priced options and color selections found in the given rows of a factory order form.',
        input_schema: {
          type: 'object',
          required: %w[options],
          properties: {
            tab_title: { type: 'string' },
            markup_multiplier: { type: 'number', description: 'The MARKUP / % multiplier stated on the tab' },
            tab_date: { type: 'string' },
            stale: { type: 'object', properties: { is_stale: { type: 'boolean' }, reason: { type: 'string' } } },
            options: {
              type: 'array',
              items: {
                type: 'object',
                required: %w[section description],
                properties: {
                  section: { type: 'string', description: 'Nearest section header above, e.g. DRYWALL, COUNTERTOPS' },
                  description: { type: 'string', description: 'Option text exactly as written' },
                  dealer_cost: { type: 'number' }, dealer_cost_cell: { type: 'string', description: 'e.g. C12' },
                  retail: { type: 'number' }, retail_cell: { type: 'string' },
                  is_standard: { type: 'boolean', description: 'Priced as STD / Std / included' },
                  applies_to: {
                    type: 'object',
                    properties: {
                      box_length_min_ft: { type: 'integer' }, box_length_max_ft: { type: 'integer' },
                      width_ft: { type: 'integer' },
                      section_type: { type: 'string', enum: %w[single multi any] },
                      construction: { type: 'string', enum: %w[vog drywall partial_drywall any] },
                      building_code: { type: 'string', enum: %w[HUD MOD any] },
                      model_numbers: { type: 'array', items: { type: 'string' } }
                    }
                  },
                  in_place_of: { type: 'string', description: 'For IPO / T/O swaps: the standard item it replaces' },
                  package_items: { type: 'array', items: { type: 'string' }, description: 'For packages: every item listed under it' },
                  choices: { type: 'array', items: { type: 'string' }, description: 'Selections such as colors listed for this option' },
                  notes: { type: 'string' }
                }
              }
            },
            color_choices: {
              type: 'array',
              items: { type: 'object', properties: { group: { type: 'string' }, name: { type: 'string' }, cell: { type: 'string' } } }
            }
          }
        }
      }.freeze

      PRODUCT_CHANGES = {
        name: 'record_product_changes',
        description: 'Record product change announcements.',
        input_schema: {
          type: 'object', required: %w[changes],
          properties: { changes: { type: 'array', items: { type: 'object',
            properties: { category: { type: 'string' },
                          change: { type: 'string', enum: %w[discontinued replaced new running_change unchanged info] },
                          item: { type: 'string' }, replacement: { type: 'string' }, effective: { type: 'string' } } } } }
        }
      }.freeze

      CLASSIFY = {
        name: 'classify_document',
        description: 'Say what kind of factory document this is.',
        input_schema: {
          type: 'object', required: %w[kind],
          properties: {
            kind: { type: 'string', enum: %w[price_list standards announcement image unknown] },
            reason: { type: 'string' }
          }
        }
      }.freeze
    end
  end
end
