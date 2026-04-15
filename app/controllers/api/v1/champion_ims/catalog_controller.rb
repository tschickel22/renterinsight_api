# frozen_string_literal: true

# DEPRECATED — 2026-04-15
#
# This controller previously served `GET /api/v1/champion_ims/catalog` for a
# bulk-import wizard concept that was later abandoned. Champion IMS sync now
# writes directly to the vehicles table (source='champion_ims'), so synced
# homes appear in the regular Inventory list — no separate catalog browser.
#
# The matching route was removed from config/routes.rb in the same commit.
# This file is kept as a tombstone for one release cycle, then should be
# `git rm`'d entirely.
#
# Migration path for any frontend code still calling /api/v1/champion_ims/catalog:
#   Use GET /api/v1/vehicles?source=champion_ims instead.
module Api
  module V1
    module ChampionIms
      class CatalogController < ApplicationController
        def index
          render json: {
            error: 'deprecated',
            message: 'The Champion IMS catalog endpoint has been removed. ' \
                     'Champion-sourced homes are now stored directly as vehicles. ' \
                     'Use GET /api/v1/vehicles?source=champion_ims instead.'
          }, status: :gone
        end
      end
    end
  end
end
