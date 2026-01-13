# Summit Park MH Dealership - Trade Show Demo Setup

## Quick Start (2 Steps)

### 1. Run the seed script:
```bash
cd ~/src/renterinsight_api
RAILS_ENV=development bin/rails demo:mh_dealership
```

### 2. Login and explore:
- **URL:** https://localhost:5173/login
- **Email:** `t+sarah.martinez@renterinsight.com`
- **Password:** `demo123`

---

## What Gets Created

### Company
- **Name:** Summit Park Manufactured Homes
- **Type:** MH Dealership (Sales & Service)
- **Locations:**
  - Denver Showroom (main sales)
  - Aurora Sales Center (satellite)
  - Service & Parts Department

### Users (All password: `demo123`)
| Email | Name | Title | Role |
|-------|------|-------|------|
| t+sarah.martinez@renterinsight.com | Sarah Martinez | Sales Manager | Admin |
| t+mike.chen@renterinsight.com | Mike Chen | Senior Sales Consultant | Staff |
| t+jessica.brown@renterinsight.com | Jessica Brown | Sales Consultant | Staff |
| t+david.wilson@renterinsight.com | David Wilson | Service Manager | Staff |
| t+amanda.garcia@renterinsight.com | Amanda Garcia | Finance Manager | Staff |

### Inventory
- **30 Manufactured Homes:**
  - 10 Single-wide ($45k-$75k)
  - 15 Double-wide ($85k-$145k)
  - 5 Triple-wide ($150k-$250k)
- **5 RVs** (Class A/C, Travel Trailers)

### CRM Data
- **60 Leads** (various stages: new → negotiation)
- **15 Active Deals** (in proposal/financing/closing)
- **20 Customer Contacts** (past buyers)

### Operations
- **25 Service Tickets** (warranty, maintenance, repairs)
- All with realistic images from Unsplash

---

## Commands

### Create Demo Data
```bash
# First time or after changes
bin/rails demo:mh_dealership
```

### Reset Demo Data (Clear & Recreate)
```bash
# If you need to start fresh
bin/rails demo:reset_mh
```

### Deploy to Staging
```bash
# 1. Push code to staging branch
git add db/seeds/mh_trade_show_demo.rb lib/tasks/demo.rake
git commit -m "Add MH trade show demo seed"
git push origin staging

# 2. SSH into Render and run:
RAILS_ENV=staging bin/rails demo:mh_dealership
```

---

## Trade Show Demo Flow

### Dashboard
- Shows portfolio overview
- 30 homes in inventory
- 60 active leads
- 15 deals in pipeline

### Inventory
- Filter by home type (single/double/triple)
- Search by price range
- View detailed home specs with photos

### CRM Pipeline
- Leads at various stages
- Deal progression tracking
- Contact management

### Service Department
- Active service tickets
- Warranty claims
- Customer history

---

## Troubleshooting

### "Company already exists"
```bash
bin/rails demo:reset_mh  # Clears and recreates
```

### "Images not loading"
- Unsplash URLs require internet connection
- Check browser network tab for CORS issues

### "Can't login"
- Verify email: `t+sarah.martinez@renterinsight.com`
- Password: `demo123`
- Check user was created: `bin/rails runner "puts User.where(email: 't+sarah.martinez@renterinsight.com').count"`

---

## Notes

- All data is **fake** and clearly marked as demo
- Company has `is_demo: true` flag
- External payment ID bypasses Zego (`99999999`)
- Images sourced from Unsplash (free, no attribution required for internal use)

**Ready for trade show in 2 days!** 🎉
