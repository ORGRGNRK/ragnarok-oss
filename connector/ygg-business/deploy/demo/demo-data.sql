-- Generic demonstration data for app_db (public.items, public.leads, public.channels).
-- Free of any personal, proprietary or real-world identifiers.

INSERT INTO public.items (sku, name, category, condition, status, cost_basis, list_price, sold_price, sold_date, quantity, platform, notes)
VALUES
  ('SKU-1001', 'Wireless Noise-Canceling Headphones', 'Audio', 'New', 'sold', 120.00, 249.99, 230.00, CURRENT_DATE - INTERVAL '5 days', 1, 'Online Store', 'Sealed box unit'),
  ('SKU-1002', 'Mechanical Ergonomic Keyboard', 'Peripherals', 'Like New', 'active', 75.00, 150.00, NULL, NULL, 2, 'Marketplace', 'Lubed switches, complete accessories'),
  ('SKU-1003', '4K UltraHD Monitor 27-inch', 'Displays', 'Refurbished', 'active', 180.00, 320.00, NULL, NULL, 1, 'Direct', 'Factory inspected, zero dead pixels'),
  ('SKU-1004', 'Compact Thunderbolt Docking Station', 'Accessories', 'New', 'sold', 90.00, 199.99, 185.00, CURRENT_DATE - INTERVAL '12 days', 1, 'Wholesale', 'Dual-display model'),
  ('SKU-1005', 'Studio Condenser USB-C Microphone', 'Audio', 'Good', 'active', 45.00, 95.00, NULL, NULL, 1, 'Marketplace', 'Minor scuff on desktop stand');

INSERT INTO public.leads (title, contact, stage, target_value, offer_value, source, notes)
VALUES
  ('Corporate Bulk Laptop Refresh (20 units)', 'procurement@acme-corp.local', 'qualified', 12000.00, 9500.00, 'Direct Outreach', 'Enterprise lease returns'),
  ('Audio Equipment Liquidation Lot', 'studio-liquidations@partner.local', 'proposal', 3500.00, 2400.00, 'Inbound Referral', 'Studio upgrade batch'),
  ('Excess Inventory Peripherals Pallet', 'sales@distributor-hub.local', 'new', 5000.00, NULL, 'Supplier Portal', 'Awaiting manifest verification');

INSERT INTO public.channels (name, type, fee_pct, active, notes)
VALUES
  ('Global B2B Wholesale Portal', 'wholesale', 3.50, true, 'High volume, fast turnaround'),
  ('Direct Enterprise Storefront', 'direct', 1.50, true, 'Zero marketplace commission, stripe processing only'),
  ('Secondary Electronics Exchange', 'marketplace', 8.00, true, 'Consumer platform with built-in buyer shipping');
