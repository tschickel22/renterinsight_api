# frozen_string_literal: true

# Professional Brochure Templates for RV and Manufactured Homes
puts "🎨 Seeding Brochure Templates..."

templates = [
  {
    name: 'RV Adventure Classic',
    description: 'Clean, professional layout perfect for RV dealerships. Emphasizes outdoor lifestyle and adventure.',
    template_key: 'rv_adventure_classic',
    theme: 'adventure',
    is_default: true,
    preview_image: '/templates/rv-adventure-preview.jpg',
    template_data: {
      blocks: [
        {
          id: 'hero-1',
          type: 'hero',
          config: {
            title: 'Start Your Adventure',
            subtitle: 'Premium RVs for Every Journey',
            backgroundImage: nil,
            textColor: '#ffffff'
          }
        },
        {
          id: 'gallery-1',
          type: 'gallery',
          config: {
            title: 'Featured RVs',
            subtitle: 'Explore our selection of quality recreational vehicles',
            layout: 'grid',
            maxItems: 20,
            showPrices: true,
            showSpecs: true,
            showDescription: true,
            highlightSpecs: ['sleeps', 'length', 'year']
          }
        }
      ],
      styles: {
        primaryColor: '#2563eb',
        secondaryColor: '#1e40af',
        accentColor: '#f59e0b',
        fontFamily: 'Inter, system-ui, sans-serif',
        headingFont: 'Inter, system-ui, sans-serif'
      }
    }
  },
  {
    name: 'RV Luxury Showcase',
    description: 'Elegant, sophisticated design for luxury RV brands. Perfect for high-end coaches and motorhomes.',
    template_key: 'rv_luxury_showcase',
    theme: 'luxury',
    is_default: true,
    preview_image: '/templates/rv-luxury-preview.jpg',
    template_data: {
      blocks: [
        {
          id: 'hero-1',
          type: 'hero',
          config: {
            title: 'Luxury On Wheels',
            subtitle: 'Experience Premium Travel in Unparalleled Comfort',
            backgroundImage: nil,
            textColor: '#ffffff'
          }
        },
        {
          id: 'gallery-1',
          type: 'gallery',
          config: {
            title: 'Our Collection',
            subtitle: 'Handpicked luxury recreational vehicles',
            layout: 'showcase',
            maxItems: 15,
            showPrices: true,
            showSpecs: true,
            showDescription: true,
            highlightSpecs: ['year', 'length', 'sleeps'],
            imageStyle: 'large'
          }
        }
      ],
      styles: {
        primaryColor: '#1e293b',
        secondaryColor: '#0f172a',
        accentColor: '#d4af37',
        fontFamily: 'Playfair Display, Georgia, serif',
        headingFont: 'Playfair Display, Georgia, serif'
      }
    }
  },
  {
    name: 'MH Family Living',
    description: 'Warm, welcoming design for manufactured homes. Emphasizes comfort, space, and family lifestyle.',
    template_key: 'mh_family_living',
    theme: 'family',
    is_default: true,
    preview_image: '/templates/mh-family-preview.jpg',
    template_data: {
      blocks: [
        {
          id: 'hero-1',
          type: 'hero',
          config: {
            title: 'Find Your Dream Home',
            subtitle: 'Quality Manufactured Homes for Modern Living',
            backgroundImage: nil,
            textColor: '#ffffff'
          }
        },
        {
          id: 'gallery-1',
          type: 'gallery',
          config: {
            title: 'Available Homes',
            subtitle: 'Spacious, affordable homes ready for you',
            layout: 'grid',
            maxItems: 20,
            showPrices: true,
            showSpecs: true,
            showDescription: true,
            highlightSpecs: ['bedrooms', 'bathrooms', 'sqft', 'year']
          }
        }
      ],
      styles: {
        primaryColor: '#059669',
        secondaryColor: '#047857',
        accentColor: '#f59e0b',
        fontFamily: 'system-ui, -apple-system, sans-serif',
        headingFont: 'system-ui, -apple-system, sans-serif'
      }
    }
  },
  {
    name: 'MH Modern Minimalist',
    description: 'Contemporary, clean design for modern manufactured home communities. Focus on lifestyle and amenities.',
    template_key: 'mh_modern_minimalist',
    theme: 'modern',
    is_default: true,
    preview_image: '/templates/mh-modern-preview.jpg',
    template_data: {
      blocks: [
        {
          id: 'hero-1',
          type: 'hero',
          config: {
            title: 'Modern Living Simplified',
            subtitle: 'Contemporary Manufactured Homes Designed for Today',
            backgroundImage: nil,
            textColor: '#ffffff'
          }
        },
        {
          id: 'gallery-1',
          type: 'gallery',
          config: {
            title: 'Our Homes',
            subtitle: 'Discover modern design meets affordability',
            layout: 'minimal',
            maxItems: 18,
            showPrices: true,
            showSpecs: true,
            showDescription: true,
            highlightSpecs: ['sqft', 'bedrooms', 'bathrooms']
          }
        }
      ],
      styles: {
        primaryColor: '#0ea5e9',
        secondaryColor: '#0284c7',
        accentColor: '#f59e0b',
        fontFamily: 'Inter, system-ui, sans-serif',
        headingFont: 'Inter, system-ui, sans-serif'
      }
    }
  },
  {
    name: 'Classic Professional',
    description: 'Versatile template suitable for both RVs and MH. Professional layout with focus on details.',
    template_key: 'classic_professional',
    theme: 'classic',
    is_default: true,
    preview_image: '/templates/classic-preview.jpg',
    template_data: {
      blocks: [
        {
          id: 'hero-1',
          type: 'hero',
          config: {
            title: 'Premium Properties',
            subtitle: 'Quality Homes and RVs You Can Trust',
            backgroundImage: nil,
            textColor: '#ffffff'
          }
        },
        {
          id: 'gallery-1',
          type: 'gallery',
          config: {
            title: 'Available Now',
            subtitle: 'Browse our current inventory',
            layout: 'classic',
            maxItems: 25,
            showPrices: true,
            showSpecs: true,
            showDescription: true
          }
        }
      ],
      styles: {
        primaryColor: '#3b82f6',
        secondaryColor: '#2563eb',
        accentColor: '#f59e0b',
        fontFamily: 'system-ui, -apple-system, sans-serif',
        headingFont: 'system-ui, -apple-system, sans-serif'
      }
    }
  },
  {
    name: 'Outdoor Explorer',
    description: 'Nature-inspired design for RVs focused on camping and outdoor adventures. Earthy, adventurous feel.',
    template_key: 'outdoor_explorer',
    theme: 'outdoor',
    is_default: true,
    preview_image: '/templates/outdoor-preview.jpg',
    template_data: {
      blocks: [
        {
          id: 'hero-1',
          type: 'hero',
          config: {
            title: 'Adventure Awaits',
            subtitle: 'Your Gateway to the Great Outdoors',
            backgroundImage: nil,
            textColor: '#ffffff'
          }
        },
        {
          id: 'gallery-1',
          type: 'gallery',
          config: {
            title: 'Adventure-Ready RVs',
            subtitle: 'Built for exploration and outdoor living',
            layout: 'adventure',
            maxItems: 15,
            showPrices: true,
            showSpecs: true,
            showDescription: true,
            highlightSpecs: ['sleeps', 'length', 'year']
          }
        }
      ],
      styles: {
        primaryColor: '#16a34a',
        secondaryColor: '#15803d',
        accentColor: '#f59e0b',
        fontFamily: 'system-ui, -apple-system, sans-serif',
        headingFont: 'system-ui, -apple-system, sans-serif'
      }
    }
  }
]

templates.each do |template_data|
  template = BrochureTemplate.find_or_initialize_by(template_key: template_data[:template_key])
  template.assign_attributes(template_data)
  
  if template.save
    puts "  ✅ Created/Updated template: #{template.name}"
  else
    puts "  ❌ Failed to create template: #{template.name} - #{template.errors.full_messages.join(', ')}"
  end
end

puts "✨ Template seeding complete! #{BrochureTemplate.count} total templates."
