# frozen_string_literal: true

# libvips keeps recent operations and their pixels in a cache so a repeated
# call is free. TrueView never repeats one: each drawing opens its own photos,
# cuts its layer and is done. With the default cache (up to 100 MB and 100
# operations per process, on top of the images in use) memory only climbed
# while a factory run drew, until staging was killed at 2 GB on 2026-11-11.
#
# A small cap keeps memory tied to the images actually in use. Nothing here
# changes what is drawn.
if defined?(Vips)
  Vips.cache_set_max(10)
  Vips.cache_set_max_mem(20 * 1024 * 1024)
  Vips.cache_set_max_files(10)
end
